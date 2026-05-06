# typed: false

require "test_helper"

class DecisionAuditEntryTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @option = create_option(decision: @decision, created_by: @user, title: "Option A")
  end

  test "ACTIONS constant contains all expected actions" do
    expected = %w[decision_created decision_updated option_added option_removed option_updated vote_cast vote_updated decision_closed beacon_drawn]
    assert_equal expected.sort, DecisionAuditEntry::ACTIONS.sort
  end

  test "CURRENT_SCHEMA_VERSION is 1" do
    assert_equal 1, DecisionAuditEntry::CURRENT_SCHEMA_VERSION
  end

  test "validates action inclusion" do
    entry = DecisionAuditEntry.new(
      tenant: @tenant,
      collective: @collective,
      decision: @decision,
      sequence_number: 1,
      schema_version: 1,
      action: "invalid_action",
      actor_id: @user.id,
      actor_handle: @user.handle,
      option_title: @option.title,
      entry_hash: "abc123",
    )
    assert_not entry.valid?
    assert entry.errors[:action].present?
  end

  test "validates schema_version presence" do
    entry = DecisionAuditEntry.new(
      tenant: @tenant,
      collective: @collective,
      decision: @decision,
      sequence_number: 1,
      schema_version: nil,
      action: "option_added",
      actor_id: @user.id,
      actor_handle: @user.handle,
      option_title: @option.title,
      entry_hash: "abc123",
    )
    assert_not entry.valid?
    assert entry.errors[:schema_version].present?
  end

  test "validates sequence_number presence" do
    entry = DecisionAuditEntry.new(
      tenant: @tenant,
      collective: @collective,
      decision: @decision,
      sequence_number: nil,
      schema_version: 1,
      action: "option_added",
      actor_id: @user.id,
      actor_handle: @user.handle,
      option_title: @option.title,
      entry_hash: "abc123",
    )
    assert_not entry.valid?
    assert entry.errors[:sequence_number].present?
  end

  test "validates entry_hash presence" do
    entry = DecisionAuditEntry.new(
      tenant: @tenant,
      collective: @collective,
      decision: @decision,
      sequence_number: 1,
      schema_version: 1,
      action: "option_added",
      actor_id: @user.id,
      actor_handle: @user.handle,
      option_title: @option.title,
      entry_hash: nil,
    )
    assert_not entry.valid?
    assert entry.errors[:entry_hash].present?
  end

  test "belongs to decision" do
    entry = DecisionAuditEntry.create!(
      tenant: @tenant,
      collective: @collective,
      decision: @decision,
      sequence_number: 1,
      schema_version: 1,
      action: "option_added",
      actor_id: @user.id,
      actor_handle: @user.handle,
      option_title: @option.title,
      entry_hash: "abc123",
    )
    assert_equal @decision, entry.decision
  end

  test "implicit_order_column is sequence_number" do
    assert_equal "sequence_number", DecisionAuditEntry.implicit_order_column
  end

  test "sequence_number is unique per decision" do
    DecisionAuditEntry.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      sequence_number: 1, schema_version: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: @option.title,
      entry_hash: "abc123",
    )
    assert_raises(ActiveRecord::RecordNotUnique) do
      DecisionAuditEntry.create!(
        tenant: @tenant, collective: @collective, decision: @decision,
        sequence_number: 1, schema_version: 1, action: "option_added",
        actor_id: @user.id, actor_handle: @user.handle, option_title: @option.title,
        entry_hash: "def456",
      )
    end
  end

  test "decision has_many decision_audit_entries" do
    entry = DecisionAuditEntry.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      sequence_number: 1, schema_version: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: @option.title,
      entry_hash: "abc123",
    )
    assert_includes @decision.decision_audit_entries, entry
  end

  test "receipt_for_user returns the user's last entry, not another user's" do
    # Alice votes
    alice = @user
    DecisionAuditService.record_option!(decision: @decision, option: @option, actor: alice, action: "option_added")
    alice_vote_entry = DecisionAuditService.record_vote!(
      decision: @decision,
      vote: Vote.new(option: @option, accepted: 1, preferred: 0),
      actor: alice,
    )

    # Bob votes after Alice
    bob = create_user(email: "bob-receipt-#{SecureRandom.hex(4)}@example.com", name: "Bob")
    @tenant.add_user!(bob)
    bob_entry = DecisionAuditService.record_vote!(
      decision: @decision,
      vote: Vote.new(option: @option, accepted: 1, preferred: 1),
      actor: bob,
    )

    # Alice's receipt is her vote entry, not Bob's
    assert_equal alice_vote_entry.entry_hash, DecisionAuditEntry.receipt_for_user(@decision, alice)&.entry_hash
    assert_equal bob_entry.entry_hash, DecisionAuditEntry.receipt_for_user(@decision, bob)&.entry_hash
    assert_not_equal alice_vote_entry.entry_hash, bob_entry.entry_hash
  end

  test "receipt_for_user returns nil when user has no entries" do
    other_user = create_user(email: "nobody-#{SecureRandom.hex(4)}@example.com", name: "Nobody")
    assert_nil DecisionAuditEntry.receipt_for_user(@decision, other_user)
  end
end
