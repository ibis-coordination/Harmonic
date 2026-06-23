# typed: false

require "test_helper"

class CleanupAbandonedBridgeSetupsJobTest < ActiveJob::TestCase
  setup do
    @tenant, _collective, @human = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @agent = create_ai_agent(parent: @human, name: "Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@agent)
    Tenant.clear_thread_scope
  end

  def make_setup(**overrides)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    s = HarmonicBridgeSetup.create!(
      tenant: @tenant,
      ai_agent_user: @agent,
      created_by_user: @human,
      **overrides
    )
    Tenant.clear_thread_scope
    s
  end

  test "destroys expired-unfinished setups and their orphaned token + rule" do
    # GETted but never POSTed. Setup is expired. Token + rule were minted
    # at redeem and have outlived the setup's intended lifetime.
    setup = make_setup
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    setup.redeem!
    Tenant.clear_thread_scope
    token_id = setup.api_token.id
    rule_id = setup.automation_rule.id
    setup.update_columns(expires_at: 2.hours.ago)

    CleanupAbandonedBridgeSetupsJob.perform_now

    assert_nil HarmonicBridgeSetup.unscoped_for_system_job.find_by(id: setup.id)
    assert_nil ApiToken.unscoped_for_system_job.find_by(id: token_id)
    assert_nil AutomationRule.unscoped_for_system_job.find_by(id: rule_id)
  end

  test "leaves finalized setups + their live token + rule alone" do
    # Successfully completed setup. Its rule + token are live in-use
    # credentials and must not be touched.
    setup = make_setup
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    setup.redeem!
    setup.stage_webhook!(webhook_url: "https://example.com/webhook/x", events: ["notifications.delivered"])
    setup.finalize_webhook!
    Tenant.clear_thread_scope
    setup.update_columns(expires_at: 2.hours.ago) # setup expires after success

    token_id = setup.api_token.id
    rule_id = setup.automation_rule.id

    CleanupAbandonedBridgeSetupsJob.perform_now

    # Setup row itself is also kept for audit; only abandoned ones are swept.
    assert_not_nil HarmonicBridgeSetup.unscoped_for_system_job.find_by(id: setup.id)
    assert_not_nil ApiToken.unscoped_for_system_job.find_by(id: token_id)
    assert_not_nil AutomationRule.unscoped_for_system_job.find_by(id: rule_id)
  end

  test "leaves unexpired setups alone (even if abandoned-in-progress)" do
    setup = make_setup
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    setup.redeem!
    Tenant.clear_thread_scope
    # expires_at default is 15 minutes in the future — still within grace.

    token_id = setup.api_token.id
    rule_id = setup.automation_rule.id

    CleanupAbandonedBridgeSetupsJob.perform_now

    assert_not_nil ApiToken.unscoped_for_system_job.find_by(id: token_id)
    assert_not_nil AutomationRule.unscoped_for_system_job.find_by(id: rule_id)
  end

  test "leaves never-redeemed setups alone (no credentials minted yet)" do
    setup = make_setup
    setup.update_columns(expires_at: 2.hours.ago)
    # No redeem!: no token, no rule. Job has nothing to clean up — the setup
    # row itself can hang around or get GC'd later; not this job's concern.
    assert_nothing_raised { CleanupAbandonedBridgeSetupsJob.perform_now }
  end
end
