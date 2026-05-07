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

  # --- verify_vote_tallies tests ---

  test "verify_vote_tallies passes when replayed votes match results" do
    option_b = create_option(decision: @decision, created_by: @user, title: "Option B")
    user2 = create_user(name: "User Two")
    @tenant.add_user!(user2)
    @collective.add_user!(user2)

    participant1 = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    participant2 = DecisionParticipantManager.new(decision: @decision, user: user2).find_or_create_participant

    vote_a = Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: @option, decision_participant: participant1, accepted: 1, preferred: 1)
    DecisionAuditService.record_vote!(decision: @decision, vote: vote_a, actor: @user)

    vote_b = Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: option_b, decision_participant: participant1, accepted: 1, preferred: 0)
    DecisionAuditService.record_vote!(decision: @decision, vote: vote_b, actor: @user)

    vote_a2 = Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: @option, decision_participant: participant2, accepted: 0, preferred: 0)
    DecisionAuditService.record_vote!(decision: @decision, vote: vote_a2, actor: user2)

    result = DecisionAuditVerifier.verify_vote_tallies(@decision)
    assert result[:valid], "Expected valid but got errors: #{result[:errors]}"
    assert_empty result[:errors]
  end

  test "verify_vote_tallies detects acceptance count mismatch" do
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: @option, decision_participant: participant, accepted: 1, preferred: 0)
    DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user)

    # Tamper: directly update the vote to change the count without an audit entry
    vote.update_columns(accepted: 0)

    result = DecisionAuditVerifier.verify_vote_tallies(@decision)
    assert_not result[:valid]
    assert result[:errors].any? { |e| e.include?("acceptance count") }
  end

  test "verify_vote_tallies detects preference count mismatch" do
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: @option, decision_participant: participant, accepted: 1, preferred: 1)
    DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user)

    # Tamper: directly update the preference
    vote.update_columns(preferred: 0)

    result = DecisionAuditVerifier.verify_vote_tallies(@decision)
    assert_not result[:valid]
    assert result[:errors].any? { |e| e.include?("preference count") }
  end

  test "verify_vote_tallies handles vote_updated correctly" do
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(tenant: @tenant, collective: @collective, decision: @decision, option: @option, decision_participant: participant, accepted: 0, preferred: 0)
    DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user)

    # Update the vote
    vote.update_columns(accepted: 1, preferred: 1)
    DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user, is_update: true)

    result = DecisionAuditVerifier.verify_vote_tallies(@decision)
    assert result[:valid], "Expected valid but got errors: #{result[:errors]}"
  end

  test "verify_vote_tallies passes with no votes (lottery)" do
    result = DecisionAuditVerifier.verify_vote_tallies(@decision)
    assert result[:valid]
    assert_empty result[:errors]
  end

  # --- verify_beacon tests ---

  test "verify_beacon passes when round and sort keys match" do
    randomness = "a1b2c3d4e5f6" * 5
    round = RandomnessProvider.current.round_for_timestamp(T.must(@decision.deadline))
    @decision.update_columns(
      lottery_beacon_round: round,
      lottery_beacon_randomness: randomness,
    )

    result = DecisionAuditVerifier.verify_beacon(@decision, fetched_randomness: randomness)
    assert result[:valid], "Expected valid but got errors: #{result[:errors]}"
  end

  test "verify_beacon detects round mismatch" do
    randomness = "a1b2c3d4e5f6" * 5
    wrong_round = 999
    @decision.update_columns(
      lottery_beacon_round: wrong_round,
      lottery_beacon_randomness: randomness,
    )

    result = DecisionAuditVerifier.verify_beacon(@decision, fetched_randomness: randomness)
    assert_not result[:valid]
    assert result[:errors].any? { |e| e.include?("round") }
  end

  test "verify_beacon detects sort key mismatch" do
    randomness = "a1b2c3d4e5f6" * 5
    round = RandomnessProvider.current.round_for_timestamp(T.must(@decision.deadline))
    @decision.update_columns(
      lottery_beacon_round: round,
      lottery_beacon_randomness: "different_randomness_value",
    )

    result = DecisionAuditVerifier.verify_beacon(@decision, fetched_randomness: randomness)
    assert_not result[:valid]
    assert result[:errors].any? { |e| e.include?("randomness") }
  end

  test "verify_beacon skips when no beacon present" do
    result = DecisionAuditVerifier.verify_beacon(@decision, fetched_randomness: nil)
    assert result[:valid]
    assert_not result[:skipped]
    assert_empty result[:errors]
  end

  test "verify_beacon returns skipped when beacon drawn but no randomness provided" do
    round = RandomnessProvider.current.round_for_timestamp(T.must(@decision.deadline))
    @decision.update_columns(
      lottery_beacon_round: round,
      lottery_beacon_randomness: "abc123",
    )

    result = DecisionAuditVerifier.verify_beacon(@decision, fetched_randomness: nil)
    assert result[:valid]
    assert result[:skipped]
    assert result[:errors].any? { |e| e.include?("Could not fetch") }
  end

  # --- verify_all tests ---

  test "verify_all returns combined results for all checks" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )

    result = DecisionAuditVerifier.verify_all(@decision)
    assert result[:valid]
    assert result[:chain][:valid]
    assert result[:vote_tallies][:valid]
    assert result[:beacon][:valid]
  end
end
