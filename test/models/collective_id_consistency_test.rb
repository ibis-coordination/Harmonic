# typed: false

require "test_helper"

# Enforces that child records (Option, Vote, DecisionParticipant, CommitmentParticipant)
# have a collective_id matching their parent's collective_id.
#
# Without these validations, ApplicationRecord#set_collective_id (which pulls from
# Collective.current_id) can populate a child with a different collective than its
# parent if the thread-local scope is misaligned. The orphan then evades collective-
# scoped cleanup in DataDeletionManager#delete_collective!. These validations make
# such a state unreachable.
class CollectiveIdConsistencyTest < ActiveSupport::TestCase
  setup do
    @tenant_a, @collective_a, @user = create_tenant_collective_user
    @collective_b = create_collective(tenant: @tenant_a, created_by: @user, name: "B", handle: "b-#{SecureRandom.hex(4)}")
    @collective_b.add_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant_a.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant_a.subdomain, handle: @collective_a.handle)
    @decision = create_decision(tenant: @tenant_a, collective: @collective_a, created_by: @user)
    @participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    @commitment = create_commitment(tenant: @tenant_a, collective: @collective_a, created_by: @user)
  end

  teardown do
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  test "Option rejects collective_id that does not match its decision" do
    option = Option.new(
      tenant: @tenant_a, collective: @collective_b,
      decision: @decision, decision_participant: @participant, title: "X",
    )
    assert_not option.valid?
    assert_includes option.errors[:collective_id].first.to_s, "decision"
  end

  test "Vote rejects collective_id that does not match its decision" do
    option = create_option(tenant: @tenant_a, collective: @collective_a, decision: @decision, created_by: @user)
    vote = Vote.new(
      tenant: @tenant_a, collective: @collective_b,
      decision: @decision, option: option, decision_participant: @participant,
      accepted: 1, preferred: 0,
    )
    assert_not vote.valid?
    assert_includes vote.errors[:collective_id].first.to_s, "decision"
  end

  test "DecisionParticipant rejects collective_id that does not match its decision" do
    participant = DecisionParticipant.new(
      tenant: @tenant_a, collective: @collective_b,
      decision: @decision, user: @user,
    )
    assert_not participant.valid?
    assert_includes participant.errors[:collective_id].first.to_s, "decision"
  end

  test "CommitmentParticipant rejects collective_id that does not match its commitment" do
    participant = CommitmentParticipant.new(
      tenant: @tenant_a, collective: @collective_b,
      commitment: @commitment, user: @user,
    )
    assert_not participant.valid?
    assert_includes participant.errors[:collective_id].first.to_s, "commitment"
  end

  test "matching collective_id passes validation" do
    option = Option.new(
      tenant: @tenant_a, collective: @collective_a,
      decision: @decision, decision_participant: @participant, title: "ok",
    )
    assert option.valid?, option.errors.full_messages.to_sentence
  end

  test "DecisionAuditEntry rejects collective_id that does not match its decision" do
    entry = DecisionAuditEntry.new(
      tenant: @tenant_a, collective: @collective_b,
      decision: @decision, action: "decision_created",
      actor_id: @user.id, actor_handle: "u",
      sequence_number: 0, previous_hash: "0" * 64, entry_hash: "1" * 64,
    )
    assert_not entry.valid?
    assert_includes entry.errors[:collective_id].first.to_s, "decision"
  end
end
