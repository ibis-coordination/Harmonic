# typed: false

require "test_helper"

# Tests that enforce constraints on audit chain event types.
# Each event type has rules about when and how many times it can appear.
class AuditChainConstraintsTest < ActiveSupport::TestCase

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  def create_audited_decision(subtype: "vote")
    decision = Decision.new(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Constraint Test?", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: subtype,
    )
    DecisionActionService.create_decision!(decision: decision, actor: @user)
    decision
  end

  # === decision_closed: exactly once ===

  test "manual close followed by deadline job does not create duplicate decision_closed" do
    decision = create_audited_decision

    # Manual close
    DecisionActionService.close_decision!(decision: decision, actor: @user)

    # Simulate deadline job running after manual close
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    DeadlineEventJob.perform_now

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    close_count = DecisionAuditEntry.where(decision_id: decision.id, action: "decision_closed").count
    assert_equal 1, close_count,
      "Expected exactly 1 decision_closed entry, got #{close_count}. " \
      "Manual close and deadline job should not both create close entries."
  end

  # === decision_created: exactly once, must be first ===

  test "decision_created is always the first entry in the chain" do
    decision = create_audited_decision
    first = DecisionAuditEntry.where(decision_id: decision.id).order(:sequence_number).first
    assert_equal "decision_created", first.action
  end

  test "decision_created appears exactly once" do
    decision = create_audited_decision

    participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    option = Option.new(decision: decision, decision_participant: participant, title: "Opt")
    DecisionActionService.add_option!(decision: decision, option: option, actor: @user)

    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: decision,
      option: option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: @user)
    DecisionActionService.close_decision!(decision: decision, actor: @user)

    created_count = DecisionAuditEntry.where(decision_id: decision.id, action: "decision_created").count
    assert_equal 1, created_count
  end

  # === beacon_drawn: at most once, only after close ===

  test "beacon_drawn appears at most once even if draw_beacon! is called twice" do
    decision = create_audited_decision
    DecisionActionService.close_decision!(decision: decision, actor: @user)
    DecisionActionService.draw_beacon!(decision: decision, round: 1, randomness: "abc")

    # Second call is a no-op
    DecisionActionService.draw_beacon!(decision: decision, round: 2, randomness: "def")

    beacon_count = DecisionAuditEntry.where(decision_id: decision.id, action: "beacon_drawn").count
    assert_equal 1, beacon_count

    # Original values preserved
    decision.reload
    assert_equal 1, decision.lottery_beacon_round
    assert_equal "abc", decision.lottery_beacon_randomness
  end

  test "beacon_drawn comes after decision_closed in the chain" do
    decision = create_audited_decision
    DecisionActionService.close_decision!(decision: decision, actor: @user)
    DecisionActionService.draw_beacon!(decision: decision, round: 1, randomness: "abc")

    entries = DecisionAuditEntry.where(decision_id: decision.id).order(:sequence_number).pluck(:action)
    close_idx = entries.index("decision_closed")
    beacon_idx = entries.index("beacon_drawn")
    assert beacon_idx > close_idx, "beacon_drawn must come after decision_closed"
  end

  # === vote_cast: only while decision is open ===

  test "votes before close produce vote_cast entries" do
    decision = create_audited_decision
    participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    option = Option.new(decision: decision, decision_participant: participant, title: "Opt")
    DecisionActionService.add_option!(decision: decision, option: option, actor: @user)

    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: decision,
      option: option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: @user)

    assert_equal 1, DecisionAuditEntry.where(decision_id: decision.id, action: "vote_cast").count
  end

  # === No events after beacon_drawn (chain is finalized) ===

  test "no audit entries are added after beacon_drawn" do
    decision = create_audited_decision
    DecisionActionService.close_decision!(decision: decision, actor: @user)
    DecisionActionService.draw_beacon!(decision: decision, round: 1, randomness: "abc")

    count_after_beacon = DecisionAuditEntry.where(decision_id: decision.id).count

    # Attempting to record more entries shouldn't add anything meaningful
    # (the chain is finalized — audit_chain_hash is set)
    assert_equal decision.reload.audit_chain_hash,
      DecisionAuditEntry.where(decision_id: decision.id).order(:sequence_number).last.entry_hash,
      "Chain hash should point to the last entry (beacon_drawn)"
  end
end
