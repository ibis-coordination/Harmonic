require "test_helper"

class CleanupExpiredAgentSignupsJobTest < ActiveSupport::TestCase
  setup do
    @tenant, _collective, @human = create_tenant_collective_user
    mark_activated!(@human)
  end

  teardown do
    Tenant.clear_thread_scope
  end

  def signup(email: @human.email)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    AgentSignup.start!(tenant: @tenant, principal_email: email, name: "Stickman")
  ensure
    Tenant.clear_thread_scope
  end

  def exists?(record)
    AgentSignup.tenant_scoped_only(@tenant.id).exists?(record.id)
  end

  test "deletes unclaimed signups expired for longer than the retention period" do
    matched = signup
    unmatched = signup(email: "nobody-#{SecureRandom.hex(4)}@example.com")
    declined = signup
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    declined.decline!
    Tenant.clear_thread_scope
    [matched, unmatched, declined].each { |s| s.update_columns(expires_at: 31.days.ago) }

    CleanupExpiredAgentSignupsJob.perform_now

    assert_not exists?(matched)
    assert_not exists?(unmatched)
    assert_not exists?(declined)
  end

  test "keeps open and recently expired signups" do
    open = signup
    recently_expired = signup
    recently_expired.update_columns(expires_at: 1.day.ago)

    CleanupExpiredAgentSignupsJob.perform_now

    assert exists?(open)
    assert exists?(recently_expired), "a recently expired signup must survive the retention window"
  end

  test "keeps claimed and redeemed signups however old: they record how an agent arrived" do
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    claimed = AgentSignup.start!(tenant: @tenant, principal_email: @human.email, name: "Claimed")
    redeemed = AgentSignup.start!(tenant: @tenant, principal_email: @human.email, name: "Redeemed")
    [claimed, redeemed].each do |s|
      agent = create_ai_agent(parent: @human, name: s.proposed_name, agent_configuration: { "mode" => "external" })
      @tenant.add_user!(agent)
      s.claim!(ai_agent: agent)
    end
    assert redeemed.pick_up!
    Tenant.clear_thread_scope
    [claimed, redeemed].each { |s| s.update_columns(expires_at: 90.days.ago) }

    CleanupExpiredAgentSignupsJob.perform_now

    assert exists?(claimed)
    assert exists?(redeemed)
  end
end
