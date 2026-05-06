# typed: false

require "test_helper"

class DecisionAuditServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @option = create_option(decision: @decision, created_by: @user, title: "Option A")
  end

  # --- record_creation! ---

  test "record_creation! creates a decision_created entry with initial values in metadata" do
    entry = DecisionAuditService.record_creation!(decision: @decision, actor: @user)
    assert_equal "decision_created", entry.action
    assert_equal 1, entry.sequence_number
    assert_equal @user.id, entry.actor_id
    assert_nil entry.previous_hash
    assert entry.entry_hash.present?
    assert_equal @decision.question, entry.metadata["question"]
    assert_equal @decision.description, entry.metadata["description"]
    assert_equal @decision.subtype, entry.metadata["subtype"]
    assert_equal @decision.deadline.iso8601, entry.metadata["deadline"]
    assert_equal @decision.options_open.to_s, entry.metadata["options_open"]
  end

  test "record_creation! includes decision_maker_id for executive decisions" do
    exec_decision = Decision.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Exec?", description: "test", deadline: 1.week.from_now,
      options_open: true, subtype: "executive", decision_maker: @user,
    )
    entry = DecisionAuditService.record_creation!(decision: exec_decision, actor: @user)
    assert_equal @user.id, entry.metadata["decision_maker_id"]
  end

  test "record_creation! omits decision_maker_id for vote decisions" do
    entry = DecisionAuditService.record_creation!(decision: @decision, actor: @user)
    assert_not entry.metadata.key?("decision_maker_id")
  end

  # --- record_update! ---

  test "record_update! creates a decision_updated entry with changed fields in metadata" do
    entry = DecisionAuditService.record_update!(
      decision: @decision, actor: @user,
      changes: { "deadline" => [1.week.from_now.iso8601, 2.weeks.from_now.iso8601] },
    )
    assert_equal "decision_updated", entry.action
    assert_equal @user.id, entry.actor_id
    assert entry.metadata.key?("deadline")
  end

  # --- record_option! ---

  test "record_option! creates an option_added entry" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_equal "option_added", entry.action
    assert_equal 1, entry.sequence_number
    assert_equal @user.id, entry.actor_id
    assert_equal @user.handle, entry.actor_handle
    assert_equal "Option A", entry.option_title
    assert_nil entry.accepted
    assert_nil entry.preferred
    assert_nil entry.previous_hash
    assert_equal DecisionAuditEntry::CURRENT_SCHEMA_VERSION, entry.schema_version
    assert entry.entry_hash.present?
  end

  test "record_option_update! creates an option_updated entry with old and new title" do
    entry = DecisionAuditService.record_option_update!(
      decision: @decision, option: @option, actor: @user,
      old_title: "Option A", new_title: "Option A (revised)",
    )
    assert_equal "option_updated", entry.action
    assert_equal "Option A (revised)", entry.option_title
    assert_equal({ "old_title" => "Option A", "new_title" => "Option A (revised)" }, entry.metadata)
  end

  test "record_option! creates an option_removed entry" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_removed",
    )
    assert_equal "option_removed", entry.action
    assert_equal 2, entry.sequence_number
    assert entry.previous_hash.present?
  end

  # --- record_vote! ---

  test "record_vote! creates a vote_cast entry for new vote" do
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )

    entry = DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user)
    assert_equal "vote_cast", entry.action
    assert_equal "Option A", entry.option_title
    assert_equal 1, entry.accepted
    assert_equal 0, entry.preferred
  end

  test "record_vote! creates a vote_updated entry for existing vote" do
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    # Record first vote
    DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user)

    # Update and record again
    vote.update!(accepted: 0, preferred: 1)
    entry = DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user, is_update: true)
    assert_equal "vote_updated", entry.action
    assert_equal 0, entry.accepted
    assert_equal 1, entry.preferred
    assert_equal 2, entry.sequence_number
  end

  # --- record_close! ---

  test "record_close! creates a decision_closed entry" do
    entry = DecisionAuditService.record_close!(decision: @decision, actor: @user)
    assert_equal "decision_closed", entry.action
    assert_nil entry.option_title
    assert_nil entry.accepted
    assert_nil entry.preferred
    assert_equal @user.id, entry.actor_id
  end

  # --- record_executive_selection! ---

  test "record_executive_selection! creates entry with selected titles in metadata" do
    entry = DecisionAuditService.record_executive_selection!(
      decision: @decision, actor: @user, selected_option_titles: ["Option A"],
    )
    assert_equal "executive_selection", entry.action
    assert_equal({ "selected_option_titles" => ["Option A"] }, entry.metadata)
  end

  # --- record_beacon! ---

  test "record_beacon! creates a beacon_drawn entry with metadata" do
    entry = DecisionAuditService.record_beacon!(
      decision: @decision, round: 12345, randomness: "abc123hex",
    )
    assert_equal "beacon_drawn", entry.action
    assert_nil entry.actor_id
    assert_nil entry.actor_handle
    assert_nil entry.option_title
    assert_equal({ "randomness" => "abc123hex", "round" => 12345 }, entry.metadata)
  end

  # --- Chain linking ---

  test "chain links correctly across multiple entries" do
    e1 = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_nil e1.previous_hash
    assert e1.entry_hash.present?

    e2 = DecisionAuditService.record_close!(decision: @decision, actor: @user)
    assert_equal e1.entry_hash, e2.previous_hash
    assert e2.entry_hash.present?
    assert_not_equal e1.entry_hash, e2.entry_hash

    e3 = DecisionAuditService.record_beacon!(
      decision: @decision, round: 99, randomness: "deadbeef",
    )
    assert_equal e2.entry_hash, e3.previous_hash
    assert_equal 3, e3.sequence_number
  end

  # --- Hash determinism ---

  test "hash computation is deterministic" do
    e1 = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    # Recompute hash from the stored entry's fields
    expected_input = [
      "v1",
      "",  # no previous_hash for first entry
      "1",
      "option_added",
      @user.id,
      @user.handle,
      "Option A",
      "",  # accepted is nil
      "",  # preferred is nil
      "",  # metadata is nil
      e1.created_at.iso8601,
    ].join("|")
    expected_hash = Digest::SHA256.hexdigest(expected_input)
    assert_equal expected_hash, e1.entry_hash
  end

  # --- Skips for pre-launch decisions ---

  test "returns nil for decisions created before launch date" do
    @decision.update_columns(created_at: Time.utc(2020, 1, 1))
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_nil entry
  end
end
