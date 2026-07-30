require "test_helper"

class AccountClosureServiceTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    @original_stripe_key = Stripe.api_key
    Stripe.api_key = "sk_test_fake"
  end

  def teardown
    Stripe.api_key = @original_stripe_key
  end

  def forwarder_rule_for(user)
    AutomationRule.create!(
      tenant: @tenant, user: user, created_by: user,
      name: "Forwarder #{SecureRandom.hex(3)}", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://example.com/hook" }, enabled: true,
    )
  end

  # === close! ===

  test "close! marks the user and tenant users as closing and revokes sessions" do
    RefreshToken.issue!(user: @user)

    AccountClosureService.close!(user: @user)

    assert @user.reload.closing?
    assert @user.close_requested_at.present?
    assert @user.sessions_revoked_at.present?, "sessions must be revoked at close"
    assert RefreshToken.where(user_id: @user.id).all? { |t| t.revoked_at.present? }
    assert TenantUser.for_user_across_tenants(@user).all? { |tu| tu.close_requested_at.present? }
  end

  test "close! does not destroy identity or content" do
    identity = @user.find_or_create_omni_auth_identity!
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    AccountClosureService.close!(user: @user)

    assert OmniAuthIdentity.exists?(identity.id), "login identity must survive close"
    assert_no_match(/@deleted\.user/, @user.reload.email)
    assert Note.unscoped.exists?(note.id)
  end

  test "close! disables the user's and their agents' automation rules" do
    rule = forwarder_rule_for(@user)
    agent = create_ai_agent(parent: @user)
    agent_rule = AutomationRule.create!(
      tenant: @tenant, ai_agent: agent, created_by: @user,
      name: "Agent rule", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "task" => "Do the thing" }, enabled: true,
    )

    AccountClosureService.close!(user: @user)

    assert_not rule.reload.enabled, "user rules must be disabled at close"
    assert_not rule.deleted_at.present?, "close must not soft-delete rules"
    assert_not agent_rule.reload.enabled, "agent rules must be disabled at close"
    assert TenantUser.for_user_across_tenants(agent).all? { |tu| tu.close_requested_at.present? },
           "agents must be marked closing too"
  end

  test "close! cancels the Stripe subscription but keeps the customer" do
    sc = StripeCustomer.create!(
      billable: @user, stripe_id: "cus_close_test", active: true,
      stripe_subscription_id: "sub_close_test",
    )
    cancel_stub = stub_request(:delete, %r{https://api\.stripe\.com/v1/subscriptions/sub_close_test})
      .to_return(status: 200, body: { id: "sub_close_test", status: "canceled" }.to_json)

    AccountClosureService.close!(user: @user)

    assert_requested cancel_stub
    assert_not sc.reload.active
    assert_not_requested :delete, %r{https://api\.stripe\.com/v1/customers/cus_close_test}
  end

  test "close! aborts before any state change when Stripe cancellation fails" do
    StripeCustomer.create!(
      billable: @user, stripe_id: "cus_close_fail", active: true,
      stripe_subscription_id: "sub_close_fail",
    )
    stub_request(:delete, %r{https://api\.stripe\.com/v1/subscriptions/sub_close_fail})
      .to_return(status: 500, body: { error: { message: "boom" } }.to_json)

    assert_raises(Stripe::StripeError) { AccountClosureService.close!(user: @user) }
    assert_not @user.reload.closing?
    assert_nil @user.sessions_revoked_at
  end

  test "close! is blocked while the user is sole active admin of a shared collective" do
    T.must(@collective.collective_members.find_by(user_id: @user.id)).add_role!("admin")
    other = create_user(email: "close-blk-#{SecureRandom.hex(4)}@example.com", name: "Blk Other")
    @tenant.add_user!(other)
    @collective.add_user!(other)

    error = assert_raises(RuntimeError) { AccountClosureService.close!(user: @user) }
    assert_match @collective.handle, error.message
    assert_not @user.reload.closing?
  end

  test "close! raises if the account is already closing" do
    AccountClosureService.close!(user: @user)
    assert_raises(RuntimeError) { AccountClosureService.close!(user: @user) }
  end

  # === restore! ===

  test "restore! clears closing state and re-enables what close! disabled" do
    rule = forwarder_rule_for(@user)
    agent = create_ai_agent(parent: @user)
    pre_disabled = AutomationRule.create!(
      tenant: @tenant, ai_agent: agent, created_by: @user,
      name: "Pre-disabled agent rule", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "task" => "Dormant" }, enabled: false,
    )
    pre_disabled.update!(updated_at: 2.days.ago)

    AccountClosureService.close!(user: @user)
    AccountClosureService.restore!(user: @user)

    assert_not @user.reload.closing?
    assert TenantUser.for_user_across_tenants(@user).all? { |tu| tu.close_requested_at.nil? }
    assert rule.reload.enabled, "rules disabled by close must be re-enabled"
    assert_not pre_disabled.reload.enabled, "rules disabled before close must stay disabled"
  end

  test "restore! restores agents alongside their principal" do
    agent = create_ai_agent(parent: @user)

    AccountClosureService.close!(user: @user)
    AccountClosureService.restore!(user: @user)

    assert TenantUser.for_user_across_tenants(agent).all? { |tu| tu.close_requested_at.nil? }
  end

  test "restore! raises when the account is not closing" do
    assert_raises(RuntimeError) { AccountClosureService.restore!(user: @user) }
  end

  # === scrub_due ===

  test "scrub_due matches only accounts past the grace period and not yet scrubbed" do
    AccountClosureService.close!(user: @user)
    assert_not_includes AccountClosureService.scrub_due, @user, "inside grace window"

    @user.update!(close_requested_at: (AccountClosureService::GRACE_PERIOD + 1.day).ago)
    assert_includes AccountClosureService.scrub_due, @user, "past grace window"

    @user.update!(scrubbed_at: Time.current)
    assert_not_includes AccountClosureService.scrub_due, @user, "already scrubbed"
  end
end
