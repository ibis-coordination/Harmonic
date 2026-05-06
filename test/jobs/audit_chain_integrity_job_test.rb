# typed: false

require "test_helper"

class AuditChainIntegrityJobTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @option = create_option(decision: @decision, created_by: @user, title: "Option A")
    @participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
  end

  test "passes for valid chain" do
    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: @participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: @user)

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    results = AuditChainIntegrityJob.check_decision(@decision)
    assert results[:chain_valid]
    assert_empty results[:errors]
  end

  test "detects invalid chain hashes" do
    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: @participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: @user)

    # Tamper with the hash (must disable trigger to simulate DB-level tampering)
    entry = DecisionAuditEntry.where(decision_id: @decision.id).first
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries DISABLE TRIGGER enforce_audit_entry_immutability"
    )
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql(["UPDATE decision_audit_entries SET entry_hash = 'tampered' WHERE id = ?", entry.id])
    )
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries ENABLE TRIGGER enforce_audit_entry_immutability"
    )

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    results = AuditChainIntegrityJob.check_decision(@decision)
    assert_not results[:chain_valid]
  end

  test "detects votes without corresponding audit entries" do
    # Create a vote without going through DecisionActionService
    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: @participant,
      accepted: 1, preferred: 0,
    )
    vote.save! # audit-safety-ignore: test creates vote directly to test detection

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    results = AuditChainIntegrityJob.check_decision(@decision)
    assert results[:missing_audit_entries] > 0
  end

  test "passes for decision with no audit entries (pre-launch)" do
    @decision.update_columns(created_at: Time.utc(2020, 1, 1))

    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    results = AuditChainIntegrityJob.check_decision(@decision)
    assert results[:chain_valid]
    assert results[:skipped]
  end
end
