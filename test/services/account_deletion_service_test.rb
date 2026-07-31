require "test_helper"

class AccountDeletionServiceTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

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

  # === request_deletion! ===

  test "request_deletion! marks the user and tenant users as pending deletion and revokes sessions" do
    RefreshToken.issue!(user: @user)

    AccountDeletionService.request_deletion!(user: @user)

    assert @user.reload.pending_deletion?
    assert @user.deletion_requested_at.present?
    assert @user.sessions_revoked_at.present?, "sessions must be revoked at close"
    assert RefreshToken.where(user_id: @user.id).all? { |t| t.revoked_at.present? }
    assert TenantUser.for_user_across_tenants(@user).all? { |tu| tu.deletion_requested_at.present? }
  end

  test "request_deletion! does not destroy identity or content" do
    identity = @user.find_or_create_omni_auth_identity!
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    AccountDeletionService.request_deletion!(user: @user)

    assert OmniAuthIdentity.exists?(identity.id), "login identity must survive close"
    assert_no_match(/@deleted\.user/, @user.reload.email)
    assert Note.unscoped.exists?(note.id)
  end

  test "request_deletion! disables the user's and their agents' automation rules" do
    rule = forwarder_rule_for(@user)
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    agent_rule = AutomationRule.create!(
      tenant: @tenant, ai_agent: agent, created_by: @user,
      name: "Agent rule", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "task" => "Do the thing" }, enabled: true,
    )

    AccountDeletionService.request_deletion!(user: @user)

    assert_not rule.reload.enabled, "user rules must be disabled at close"
    assert_not rule.deleted_at.present?, "close must not soft-delete rules"
    assert_not agent_rule.reload.enabled, "agent rules must be disabled at close"
    agent_tenant_users = TenantUser.for_user_across_tenants(agent).to_a
    assert agent_tenant_users.any? && agent_tenant_users.all? { |tu| tu.deletion_requested_at.present? },
           "agents must be marked pending deletion too"
  end

  test "request_deletion! cancels the Stripe subscription but keeps the customer" do
    sc = StripeCustomer.create!(
      billable: @user, stripe_id: "cus_close_test", active: true,
      stripe_subscription_id: "sub_close_test",
    )
    cancel_stub = stub_request(:delete, %r{https://api\.stripe\.com/v1/subscriptions/sub_close_test})
      .to_return(status: 200, body: { id: "sub_close_test", status: "canceled" }.to_json)

    AccountDeletionService.request_deletion!(user: @user)

    assert_requested cancel_stub
    assert_not sc.reload.active
    assert_not_requested :delete, %r{https://api\.stripe\.com/v1/customers/cus_close_test}
  end

  test "request_deletion! aborts before any state change when Stripe cancellation fails" do
    StripeCustomer.create!(
      billable: @user, stripe_id: "cus_close_fail", active: true,
      stripe_subscription_id: "sub_close_fail",
    )
    stub_request(:delete, %r{https://api\.stripe\.com/v1/subscriptions/sub_close_fail})
      .to_return(status: 500, body: { error: { message: "boom" } }.to_json)

    assert_raises(Stripe::StripeError) { AccountDeletionService.request_deletion!(user: @user) }
    assert_not @user.reload.pending_deletion?
    assert_nil @user.sessions_revoked_at
  end

  test "request_deletion! is blocked while the user is sole active admin of a shared collective" do
    T.must(@collective.collective_members.find_by(user_id: @user.id)).add_role!("admin")
    other = create_user(email: "close-blk-#{SecureRandom.hex(4)}@example.com", name: "Blk Other")
    @tenant.add_user!(other)
    @collective.add_user!(other)

    error = assert_raises(RuntimeError) { AccountDeletionService.request_deletion!(user: @user) }
    assert_match @collective.handle, error.message
    assert_not @user.reload.pending_deletion?
  end

  test "request_deletion! sends a confirmation email and resets the reminder stamp" do
    @user.update!(deletion_reminder_sent_at: 40.days.ago)

    assert_enqueued_emails 1 do
      AccountDeletionService.request_deletion!(user: @user)
    end
    assert_nil @user.reload.deletion_reminder_sent_at, "a new request starts a fresh reminder cycle"
  end

  test "request_tenant_deletion! sends a confirmation email and resets the reminder stamp" do
    add_second_tenant!(@user)
    tu = tenant_user_for(@user, @tenant)
    tu.update!(deletion_reminder_sent_at: 40.days.ago)

    assert_enqueued_emails 1 do
      AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    end
    assert_nil tu.reload.deletion_reminder_sent_at
  end

  test "request_deletion! raises when deletion is already requested" do
    AccountDeletionService.request_deletion!(user: @user)
    assert_raises(RuntimeError) { AccountDeletionService.request_deletion!(user: @user) }
  end

  test "request_deletion! refuses scrubbed accounts" do
    @user.update!(scrubbed_at: Time.current)
    assert_raises(RuntimeError) { AccountDeletionService.request_deletion!(user: @user) }
    assert_not @user.reload.pending_deletion?
  end

  test "request_deletion! refuses non-human users" do
    agent = create_ai_agent(parent: @user)
    assert_raises(RuntimeError) { AccountDeletionService.request_deletion!(user: agent) }
  end

  # === restore! ===

  test "restore! clears the pending-deletion state and re-enables what request_deletion! disabled" do
    rule = forwarder_rule_for(@user)
    agent = create_ai_agent(parent: @user)
    pre_disabled = AutomationRule.create!(
      tenant: @tenant, ai_agent: agent, created_by: @user,
      name: "Pre-disabled agent rule", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "task" => "Dormant" }, enabled: false,
    )
    pre_disabled.update!(updated_at: 2.days.ago)

    AccountDeletionService.request_deletion!(user: @user)
    AccountDeletionService.restore!(user: @user)

    assert_not @user.reload.pending_deletion?
    assert TenantUser.for_user_across_tenants(@user).all? { |tu| tu.deletion_requested_at.nil? }
    assert rule.reload.enabled, "rules disabled by close must be re-enabled"
    assert_not pre_disabled.reload.enabled, "rules disabled before close must stay disabled"
  end

  test "restore! restores agents alongside their principal" do
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)

    AccountDeletionService.request_deletion!(user: @user)
    agent_tenant_users = TenantUser.for_user_across_tenants(agent).to_a
    assert agent_tenant_users.any? && agent_tenant_users.all? { |tu| tu.deletion_requested_at.present? }

    AccountDeletionService.restore!(user: @user)
    assert TenantUser.for_user_across_tenants(agent).all? { |tu| tu.reload.deletion_requested_at.nil? }
  end

  test "restore! raises when the account is not pending deletion" do
    assert_raises(RuntimeError) { AccountDeletionService.restore!(user: @user) }
  end

  test "restore! refuses scrubbed accounts" do
    AccountDeletionService.request_deletion!(user: @user)
    @user.update!(scrubbed_at: Time.current)

    assert_raises(RuntimeError) { AccountDeletionService.restore!(user: @user) }
    assert @user.reload.deletion_requested_at.present?, "a scrubbed account's deletion state must not be cleared"
  end

  # === scrub_due ===

  test "scrub_due matches only accounts past the grace period and not yet scrubbed" do
    AccountDeletionService.request_deletion!(user: @user)
    assert_not_includes AccountDeletionService.scrub_due, @user, "inside grace window"

    @user.update!(deletion_requested_at: (AccountDeletionService::GRACE_PERIOD + 1.day).ago)
    assert_includes AccountDeletionService.scrub_due, @user, "past grace window"

    @user.update!(scrubbed_at: Time.current)
    assert_not_includes AccountDeletionService.scrub_due, @user, "already scrubbed"
  end

  # === per-subdomain deletion ===

  def add_second_tenant!(user)
    tenant_b = create_tenant
    tenant_b.add_user!(user)
    tenant_b
  end

  def tenant_user_for(user, tenant)
    TenantUser.tenant_scoped_only(tenant.id).find_by(user_id: user.id)
  end

  test "request_tenant_deletion! marks only that subdomain's account pending and leaves the rest untouched" do
    tenant_b = add_second_tenant!(@user)
    RefreshToken.issue!(user: @user)
    rule_a = forwarder_rule_for(@user)
    token_a = ApiToken.create!(tenant: @tenant, user: @user, scopes: ApiToken.read_scopes)
    token_b = ApiToken.tenant_scoped_only(tenant_b.id).create!(tenant: tenant_b, user: @user, scopes: ApiToken.read_scopes)

    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)

    assert tenant_user_for(@user, @tenant).deletion_requested_at.present?
    assert_nil tenant_user_for(@user, tenant_b).deletion_requested_at
    assert_nil @user.reload.deletion_requested_at, "per-subdomain request must not mark the account globally"
    assert_nil @user.sessions_revoked_at, "the shared session survives a per-subdomain request"
    assert RefreshToken.where(user_id: @user.id).none? { |t| t.revoked_at.present? }
    assert_not rule_a.reload.enabled, "rules in the deleted subdomain must be disabled"
    assert token_a.reload.deleted_at.present?, "API tokens in the deleted subdomain must be revoked"
    assert_nil token_b.reload.deleted_at, "API tokens in other subdomains must survive"
  end

  test "request_tenant_deletion! pauses the user's agents in that subdomain only" do
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    tenant_b = add_second_tenant!(@user)
    tenant_b.add_user!(agent)
    agent_rule = AutomationRule.create!(
      tenant: @tenant, ai_agent: agent, created_by: @user,
      name: "Agent rule", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "task" => "Do the thing" }, enabled: true,
    )

    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)

    assert tenant_user_for(agent, @tenant).deletion_requested_at.present?
    assert_nil tenant_user_for(agent, tenant_b).deletion_requested_at
    assert_not agent_rule.reload.enabled
  end

  test "request_tenant_deletion! refuses the last active subdomain account" do
    error = assert_raises(RuntimeError) do
      AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    end
    assert_match(/only subdomain account/i, error.message)
    assert_nil tenant_user_for(@user, @tenant).deletion_requested_at
  end

  test "request_tenant_deletion! sole-admin block is scoped to the requested subdomain" do
    tenant_b = add_second_tenant!(@user)
    collective_b = create_collective(tenant: tenant_b, created_by: @user)
    collective_b.add_user!(@user)
    T.must(collective_b.collective_members.find_by(user_id: @user.id)).add_role!("admin")
    other = create_user(email: "tenant-blk-#{SecureRandom.hex(4)}@example.com", name: "Tenant Blk")
    tenant_b.add_user!(other)
    collective_b.add_user!(other)

    # Sole admin of a shared collective in B: deleting A is fine, deleting B is blocked.
    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    assert tenant_user_for(@user, @tenant).deletion_requested_at.present?

    error = assert_raises(RuntimeError) do
      AccountDeletionService.request_tenant_deletion!(user: @user, tenant: tenant_b)
    end
    assert_match collective_b.handle, error.message
  end

  test "request_tenant_deletion! guards against invalid states" do
    agent = create_ai_agent(parent: @user)
    add_second_tenant!(@user)

    assert_raises(RuntimeError, "non-human") do
      AccountDeletionService.request_tenant_deletion!(user: agent, tenant: @tenant)
    end

    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    assert_raises(RuntimeError, "already requested") do
      AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    end

    tenant_user_for(@user, @tenant).update!(deletion_requested_at: nil, scrubbed_at: Time.current)
    assert_raises(RuntimeError, "tenant slice already scrubbed") do
      AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    end
  end

  test "request_tenant_deletion! refuses while global deletion is pending" do
    tenant_b = add_second_tenant!(@user)
    AccountDeletionService.request_deletion!(user: @user)

    assert_raises(RuntimeError) do
      AccountDeletionService.request_tenant_deletion!(user: @user, tenant: tenant_b)
    end
  end

  test "request_deletion! supersedes an earlier per-subdomain request and restore! clears both" do
    tenant_b = add_second_tenant!(@user)
    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    earlier = T.must(tenant_user_for(@user, @tenant).deletion_requested_at)

    travel_to(2.days.from_now) do
      AccountDeletionService.request_deletion!(user: @user)
      assert_equal earlier, tenant_user_for(@user, @tenant).deletion_requested_at,
                   "the earlier per-subdomain timestamp survives as that tenant's rules-disable boundary"
      assert tenant_user_for(@user, tenant_b).deletion_requested_at.present?

      AccountDeletionService.restore!(user: @user)
      assert_nil tenant_user_for(@user, @tenant).deletion_requested_at
      assert_nil tenant_user_for(@user, tenant_b).deletion_requested_at
    end
  end

  test "restore! after a superseding global request re-enables rules the per-subdomain request disabled" do
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    add_second_tenant!(@user)
    rule = forwarder_rule_for(@user)
    agent_rule = AutomationRule.create!(
      tenant: @tenant, ai_agent: agent, created_by: @user,
      name: "Agent rule", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "task" => "Do the thing" }, enabled: true,
    )

    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    travel_to(2.days.from_now) do
      AccountDeletionService.request_deletion!(user: @user)
      AccountDeletionService.restore!(user: @user)
    end

    assert rule.reload.enabled,
           "rules disabled by the superseded per-subdomain request must be re-enabled by the global restore"
    assert agent_rule.reload.enabled,
           "agent rules disabled by the superseded per-subdomain request must be re-enabled too"
  end

  test "restore_tenant! clears only that subdomain and re-enables what the request disabled" do
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)
    tenant_b = add_second_tenant!(@user)
    rule_a = forwarder_rule_for(@user)
    pre_disabled = AutomationRule.create!(
      tenant: @tenant, ai_agent: agent, created_by: @user,
      name: "Pre-disabled", trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "task" => "Dormant" }, enabled: false,
    )
    pre_disabled.update!(updated_at: 2.days.ago)

    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    AccountDeletionService.restore_tenant!(user: @user, tenant: @tenant)

    assert_nil tenant_user_for(@user, @tenant).deletion_requested_at
    assert_nil tenant_user_for(agent, @tenant).deletion_requested_at
    assert rule_a.reload.enabled
    assert_not pre_disabled.reload.enabled

    assert_not_nil tenant_user_for(@user, tenant_b), "other subdomain untouched"
  end

  test "restore_tenant! guards against invalid states" do
    tenant_b = add_second_tenant!(@user)

    assert_raises(RuntimeError, "not pending") do
      AccountDeletionService.restore_tenant!(user: @user, tenant: @tenant)
    end

    AccountDeletionService.request_tenant_deletion!(user: @user, tenant: @tenant)
    tenant_user_for(@user, @tenant).update!(scrubbed_at: Time.current)
    assert_raises(RuntimeError, "tenant slice already scrubbed") do
      AccountDeletionService.restore_tenant!(user: @user, tenant: @tenant)
    end

    AccountDeletionService.request_deletion!(user: @user)
    assert_raises(RuntimeError, "global pending is restored via restore!") do
      AccountDeletionService.restore_tenant!(user: @user, tenant: tenant_b)
    end
  end

end
