# typed: false

require "test_helper"

class DecisionAuditVerifierTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @option = create_option(decision: @decision, created_by: @user, title: "Option A")
  end

  test "verify_chain passes for a valid chain" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    DecisionAuditService.record_close!(decision: @decision, actor: @user)

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert result[:valid]
    assert_equal 2, result[:entry_count]
    assert_empty result[:errors]
  end

  test "verify_chain detects tampered entry_hash" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    # Tamper with the hash by directly updating via SQL (bypass immutability trigger)
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries DISABLE TRIGGER enforce_audit_entry_immutability"
    )
    ActiveRecord::Base.connection.execute(
      "UPDATE decision_audit_entries SET entry_hash = 'tampered' WHERE id = '#{entry.id}'"
    )
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries ENABLE TRIGGER enforce_audit_entry_immutability"
    )

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert_not result[:valid]
    assert result[:errors].any? { |e| e.include?("hash mismatch") }
  end

  test "verify_chain detects broken chain link" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    entry2 = DecisionAuditService.record_close!(decision: @decision, actor: @user)

    # Tamper with previous_hash
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries DISABLE TRIGGER enforce_audit_entry_immutability"
    )
    ActiveRecord::Base.connection.execute(
      "UPDATE decision_audit_entries SET previous_hash = 'wrong' WHERE id = '#{entry2.id}'"
    )
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries ENABLE TRIGGER enforce_audit_entry_immutability"
    )

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert_not result[:valid]
    assert result[:errors].any? { |e| e.include?("chain link broken") }
  end

  test "verify_chain detects gaps in sequence numbers" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    entry2 = DecisionAuditService.record_close!(decision: @decision, actor: @user)

    # Change sequence number to create a gap
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries DISABLE TRIGGER enforce_audit_entry_immutability"
    )
    # Remove the unique index temporarily, change sequence, re-add
    ActiveRecord::Base.connection.execute(
      "UPDATE decision_audit_entries SET sequence_number = 5 WHERE id = '#{entry2.id}'"
    )
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries ENABLE TRIGGER enforce_audit_entry_immutability"
    )

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert_not result[:valid]
    assert result[:errors].any? { |e| e.include?("sequence gap") }
  end

  test "verify_chain passes for empty chain" do
    result = DecisionAuditVerifier.verify_chain(@decision)
    assert result[:valid]
    assert_equal 0, result[:entry_count]
  end

  test "verify_entry recomputes and compares single entry hash" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    result = DecisionAuditVerifier.verify_entry(entry)
    assert result[:valid]
  end

  test "verify_chain checks final hash matches decision audit_chain_hash" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    last = DecisionAuditService.record_close!(decision: @decision, actor: @user)
    @decision.update_columns(audit_chain_hash: last.entry_hash)

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert result[:valid]

    # Now set wrong chain hash
    @decision.update_columns(audit_chain_hash: "wrong_hash")
    result = DecisionAuditVerifier.verify_chain(@decision)
    assert_not result[:valid]
    assert result[:errors].any? { |e| e.include?("chain hash mismatch") }
  end
end
