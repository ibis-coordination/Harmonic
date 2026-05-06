# typed: false

require "test_helper"

class DecisionActionServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @option = create_option(decision: @decision, created_by: @user, title: "Option A")
    @participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
  end

  # --- cast_vote! ---

  test "cast_vote! creates vote and audit entry in same transaction" do
    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: @participant,
      accepted: 1, preferred: 0,
    )

    result = DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: @user)
    assert vote.persisted?
    assert result[:audit_entry].present?
    assert_equal "vote_cast", result[:audit_entry].action
    assert_equal 1, DecisionAuditEntry.where(decision: @decision).count
  end

  test "cast_vote! creates vote_updated entry for existing vote" do
    vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: @participant,
      accepted: 1, preferred: 0,
    )
    # First audit entry for the initial vote
    DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: @user, is_update: false)

    vote.accepted = 0
    vote.preferred = 1
    result = DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: @user, is_update: true)
    assert_equal "vote_updated", result[:audit_entry].action
    assert_equal 2, DecisionAuditEntry.where(decision: @decision).count
  end

  # --- add_option! ---

  test "add_option! saves option and creates audit entry" do
    new_option = Option.new(
      decision: @decision,
      decision_participant: @participant,
      title: "Option B",
    )

    result = DecisionActionService.add_option!(decision: @decision, option: new_option, actor: @user)
    assert new_option.persisted?
    assert_equal "option_added", result[:audit_entry].action
    assert_equal "Option B", result[:audit_entry].option_title
  end

  # --- remove_option! ---

  test "remove_option! destroys option and creates audit entry" do
    result = DecisionActionService.remove_option!(decision: @decision, option: @option, actor: @user)
    assert @option.destroyed?
    assert_equal "option_removed", result[:audit_entry].action
    assert_equal "Option A", result[:audit_entry].option_title
  end

  # --- close_decision! ---

  test "close_decision! closes decision and creates audit entry" do
    result = DecisionActionService.close_decision!(decision: @decision, actor: @user)
    assert @decision.closed?
    assert_equal "decision_closed", result[:audit_entry].action
  end

  test "close_decision! with executive selections creates two entries and sets chain hash" do
    exec_decision = Decision.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Exec Decision?", description: "Test exec", deadline: Time.current + 1.week,
      options_open: true, subtype: "executive",
    )
    opt = create_option(decision: exec_decision, created_by: @user, title: "Exec Option")

    result = DecisionActionService.close_decision!(
      decision: exec_decision, actor: @user,
      executive_selections: ["Exec Option"],
    )
    entries = DecisionAuditEntry.where(decision: exec_decision).order(:sequence_number)
    assert_equal 2, entries.count
    assert_equal "decision_closed", entries.first.action
    assert_equal "executive_selection", entries.last.action
    assert_equal exec_decision.reload.audit_chain_hash, entries.last.entry_hash
  end

  # --- draw_beacon! ---

  test "draw_beacon! updates decision and creates audit entry with chain hash" do
    result = DecisionActionService.draw_beacon!(
      decision: @decision, round: 12345, randomness: "abc123hex",
    )
    @decision.reload
    assert_equal 12345, @decision.lottery_beacon_round
    assert_equal "abc123hex", @decision.lottery_beacon_randomness
    assert_equal "beacon_drawn", result[:audit_entry].action
    assert_equal @decision.audit_chain_hash, result[:audit_entry].entry_hash
  end

  # --- audit_receipt ---

  test "cast_vote! sets audit_receipt on the vote object" do
    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: @participant,
      accepted: 1, preferred: 0,
    )

    result = DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: @user)
    assert vote.audit_receipt.present?
    assert_equal result[:audit_entry].entry_hash, vote.audit_receipt
  end

  test "vote api_json includes audit_receipt when set" do
    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: @participant,
      accepted: 1, preferred: 0,
    )

    DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: @user)
    json = vote.api_json
    assert_equal vote.audit_receipt, json[:audit_receipt]
  end

  # --- Transaction rollback ---

  test "transaction rolls back both vote and audit entry on failure" do
    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: @participant,
      accepted: 99,  # invalid — validation will fail
      preferred: 0,
    )

    assert_raises(ActiveRecord::RecordInvalid) do
      DecisionActionService.cast_vote!(decision: @decision, vote: vote, actor: @user)
    end
    assert_equal 0, DecisionAuditEntry.where(decision: @decision).count
    assert_not vote.persisted?
  end
end
