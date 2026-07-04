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

  test "verify_vote_tallies still verifies after the participant changes their handle between vote_cast and vote_updated" do
    # Regression: replay_vote_totals dedupes votes by actor_token. If the
    # token derivation depends on the actor's current handle, a rename
    # between vote_cast and vote_updated produces two different tokens for
    # the same voter and the tally check double-counts them. The fix is to
    # anchor token derivation to the participant's first handle in the
    # decision (same lookup we already do for the salt).
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user)

    @user.handle = "renamed-#{SecureRandom.hex(4)}"
    vote.update_columns(accepted: 0)
    DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user, is_update: true)

    result = DecisionAuditVerifier.verify_vote_tallies(@decision)
    assert result[:valid],
           "Vote tally must verify after a handle change: #{result[:errors].inspect}"
  end

  test "verify_vote_tallies skips with no votes" do
    result = DecisionAuditVerifier.verify_vote_tallies(@decision)
    assert result[:valid]
    assert result[:skipped]
    assert result[:errors].any? { |e| e.include?("No votes") }
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
    assert result[:skipped]
    assert result[:errors].any? { |e| e.include?("No beacon drawn yet") }
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

  # === verify_actor_binding ===

  test "verify_actor_binding returns :verified when stored token matches the derived hash" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_equal :verified, DecisionAuditVerifier.verify_actor_binding(entry)
  end

  test "verify_actor_binding returns :no_actor for system entries with no actor" do
    entry = DecisionAuditService.record_beacon!(decision: @decision, round: 99, randomness: "deadbeef")
    assert_equal :no_actor, DecisionAuditVerifier.verify_actor_binding(entry)
  end

  test "verify_actor_binding returns :v1_chain_only for v1 entries (binding enforced by chain hash)" do
    entry = DecisionAuditEntry.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      sequence_number: 1, schema_version: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle,
      option_title: "Option A",
      created_at: Time.current.change(usec: 0),
      entry_hash: "abc",
    )
    assert_equal :v1_chain_only, DecisionAuditVerifier.verify_actor_binding(entry)
  end

  test "verify_actor_binding returns :unattributable when actor_id has been scrubbed" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    entry.update_columns(actor_id: nil, actor_handle: "[deleted account]", actor_token_salt: nil)
    assert_equal :unattributable, DecisionAuditVerifier.verify_actor_binding(entry)
  end

  test "verify_actor_binding returns :imported for entries imported from another instance" do
    # Imported entries have salt NULL'd but metadata.imported=true; this
    # distinguishes them from PII-scrubbed entries (NULL salt, no flag) so
    # downstream tooling can render an accurate explanation rather than
    # implying account-closure scrubbing happened.
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    new_metadata = (entry.metadata || {}).merge("imported" => true)
    # The immutability trigger blocks metadata updates; tests forge the
    # imported state by toggling the trigger off briefly.
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries DISABLE TRIGGER enforce_audit_entry_immutability"
    )
    entry.update_columns(actor_token_salt: nil, metadata: new_metadata)
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries ENABLE TRIGGER enforce_audit_entry_immutability"
    )
    assert_equal :imported, DecisionAuditVerifier.verify_actor_binding(entry)
  end

  test "verify_actor_binding returns :unattributable (not :imported) when salt is NULL but no imported flag" do
    # Defensive: an entry with NULL salt and no imported flag is the scrub
    # case, regardless of what other metadata contents might look like.
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    entry.update_columns(actor_token_salt: nil)
    assert_equal :unattributable, DecisionAuditVerifier.verify_actor_binding(entry)
  end

  test "verify_actor_binding returns :tamper_or_scrub_inconsistent when actor_id was changed without scrub" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    other_user = create_user(name: "Other")
    entry.update_columns(actor_id: other_user.id, actor_handle: other_user.handle)
    assert_equal :tamper_or_scrub_inconsistent, DecisionAuditVerifier.verify_actor_binding(entry)
  end

  test "verify_actor_binding returns :tamper_or_scrub_inconsistent when only actor_handle was swapped" do
    # actor_handle is part of the token derivation (anchored to first entry by
    # decision+actor), so changing just the displayed handle to misattribute
    # an action must fail binding even though actor_id is intact.
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    entry.update_columns(actor_handle: "different-handle")
    assert_equal :tamper_or_scrub_inconsistent, DecisionAuditVerifier.verify_actor_binding(entry)
  end

  # === verify_chain binding fields ===

  test "verify_chain populates binding_statuses for every entry" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    DecisionAuditService.record_beacon!(decision: @decision, round: 99, randomness: "deadbeef")

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert_equal 2, result[:binding_statuses].size
    assert_equal :verified, result[:binding_statuses][1]
    assert_equal :no_actor, result[:binding_statuses][2]
  end

  test "verify_chain.scrubbed_count counts unattributable entries" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    DecisionAuditService.record_close!(decision: @decision, actor: @user)
    DecisionAuditEntry.where(decision_id: @decision.id, actor_id: @user.id).find_each do |e|
      e.update_columns(actor_id: nil, actor_handle: "[deleted account]", actor_token_salt: nil)
    end

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert_equal 2, result[:scrubbed_count]
    assert_equal 0, result[:imported_count]
    assert_equal 0, result[:binding_inconsistent_count]
  end

  test "verify_chain.imported_count tracks imported entries separately from scrubbed" do
    e1 = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    e2 = DecisionAuditService.record_close!(decision: @decision, actor: @user)
    # e1 simulates account-closure scrub; e2 simulates a cross-instance import.
    # The metadata change on e2 invalidates its entry_hash, so we recompute
    # under a trigger-disabled window. (Real imports leave a hash mismatch on
    # disk; this test isolates the verifier accounting logic.)
    e1.update_columns(actor_id: nil, actor_handle: "[deleted account]", actor_token_salt: nil)
    e2.metadata = (e2.metadata || {}).merge("imported" => true)
    e2.actor_token_salt = nil
    new_hash = DecisionAuditService.compute_hash(e2)
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries DISABLE TRIGGER enforce_audit_entry_immutability"
    )
    e2.update_columns(metadata: e2.metadata, actor_token_salt: nil, entry_hash: new_hash)
    ActiveRecord::Base.connection.execute(
      "ALTER TABLE decision_audit_entries ENABLE TRIGGER enforce_audit_entry_immutability"
    )

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert result[:valid], "Chain stays valid: both states are intentional, not tamper. Errors: #{result[:errors].inspect}"
    assert_equal 1, result[:scrubbed_count]
    assert_equal 1, result[:imported_count]
    assert_equal 0, result[:binding_inconsistent_count]
  end

  test "verify_chain.binding_inconsistent_count drives valid to false" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    # Tamper: swap actor_id (the trigger permits this; the chain hash itself is
    # unchanged because v2 hashes actor_token, not actor_id).
    other_user = create_user(name: "Other")
    entry.update_columns(actor_id: other_user.id, actor_handle: other_user.handle)

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert_equal 1, result[:binding_inconsistent_count]
    assert_equal({ 1 => :tamper_or_scrub_inconsistent }, result[:binding_statuses])
    assert_empty result[:errors]
    refute result[:valid], "Chain with tampered identity must be invalid even though hashes match"
  end

  # === Scrub flow: chain still verifies ===

  test "chain verifies after PII scrub (NULL actor_id, scrub salt, replace handle)" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    DecisionAuditService.record_close!(decision: @decision, actor: @user)

    # Simulate account-closure scrub for @user: NULL actor_id and salt, replace handle
    DecisionAuditEntry.where(decision_id: @decision.id, actor_id: @user.id).find_each do |e|
      e.update_columns(actor_id: nil, actor_handle: "[deleted account]", actor_token_salt: nil)
    end

    # Chain integrity check still passes
    result = DecisionAuditVerifier.verify_chain(@decision)
    assert result[:valid], "Chain must still verify after scrub: #{result[:errors].inspect}"

    # And every scrubbed entry's actor binding is :unattributable
    DecisionAuditEntry.where(decision_id: @decision.id).find_each do |e|
      next if e.action == "beacon_drawn" # no actor

      assert_equal :unattributable, DecisionAuditVerifier.verify_actor_binding(e)
    end
  end

  # === verify_representative_binding (v3) ===

  def create_represented_entry(action: "option_added")
    trustee = create_user(name: "Trustee")
    @tenant.add_user!(trustee)
    @collective.add_user!(trustee)
    grant = create_trustee_authorization(
      tenant: @tenant, granting_user: @user, trustee_user: trustee,
      permissions: { "vote" => true }, accepted: true,
    )
    session = create_trustee_authorization_representation_session(tenant: @tenant, trustee_grant: grant)
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: action,
      representation_session: session,
    )
    [entry, trustee]
  end

  test "verify_representative_binding returns :verified for an intact represented entry" do
    entry, _trustee = create_represented_entry
    assert_equal :verified, DecisionAuditVerifier.verify_representative_binding(entry)
  end

  test "verify_representative_binding returns :not_represented for direct v3 entries" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_equal :not_represented, DecisionAuditVerifier.verify_representative_binding(entry)
  end

  test "verify_representative_binding returns :pre_v3 for v1/v2 entries" do
    entry = DecisionAuditEntry.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      sequence_number: 1, schema_version: 2, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, actor_token: "tok",
      option_title: "Option A",
      created_at: Time.current.change(usec: 0),
      entry_hash: "abc",
    )
    assert_equal :pre_v3, DecisionAuditVerifier.verify_representative_binding(entry)
  end

  test "verify_representative_binding returns :unattributable after representative PII scrub" do
    entry, _trustee = create_represented_entry
    entry.update_columns(representative_id: nil, representative_handle: "[deleted account]", representative_token_salt: nil)
    assert_equal :unattributable, DecisionAuditVerifier.verify_representative_binding(entry)
  end

  test "verify_representative_binding returns :tamper_or_scrub_inconsistent when representative identity is swapped" do
    entry, _trustee = create_represented_entry
    other_user = create_user(name: "Imposter")
    entry.update_columns(representative_id: other_user.id, representative_handle: other_user.handle)
    assert_equal :tamper_or_scrub_inconsistent, DecisionAuditVerifier.verify_representative_binding(entry)
  end

  test "verify_chain reports representative binding statuses and fails on representative tamper" do
    entry, _trustee = create_represented_entry
    DecisionAuditService.record_close!(decision: @decision, actor: @user)

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert result[:valid], "intact represented chain must verify: #{result[:errors].inspect}"
    assert_equal :verified, result[:representative_binding_statuses][1]
    assert_equal :not_represented, result[:representative_binding_statuses][2]

    imposter = create_user(name: "Imposter Two")
    entry.update_columns(representative_id: imposter.id, representative_handle: imposter.handle)
    result = DecisionAuditVerifier.verify_chain(@decision)
    refute result[:valid], "chain with tampered representative identity must be invalid"
    assert_equal 1, result[:representative_binding_inconsistent_count]
  end

  test "chain verifies after symmetric PII scrub of actor and representative" do
    create_represented_entry
    DecisionAuditEntry.where(decision_id: @decision.id).find_each do |e|
      e.update_columns(
        actor_id: nil, actor_handle: "[deleted account]", actor_token_salt: nil,
        representative_id: nil, representative_handle: "[deleted account]", representative_token_salt: nil,
      )
    end

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert result[:valid], "chain must verify after symmetric scrub: #{result[:errors].inspect}"
    assert_equal :unattributable, DecisionAuditVerifier.verify_representative_binding(
      DecisionAuditEntry.where(decision_id: @decision.id).first,
    )
  end

  test "verify_vote_tallies dedupes a represented vote_cast and a direct vote_updated by the same principal" do
    trustee = create_user(name: "Tally Trustee")
    @tenant.add_user!(trustee)
    @collective.add_user!(trustee)
    grant = create_trustee_authorization(
      tenant: @tenant, granting_user: @user, trustee_user: trustee,
      permissions: { "vote" => true }, accepted: true,
    )
    session = create_trustee_authorization_representation_session(tenant: @tenant, trustee_grant: grant)

    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: participant, accepted: 1, preferred: 0,
    )
    DecisionAuditService.record_vote!(
      decision: @decision, vote: vote, actor: @user, representation_session: session,
    )
    vote.update_columns(accepted: 0)
    DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user, is_update: true)

    result = DecisionAuditVerifier.verify_vote_tallies(@decision)
    assert result[:valid],
           "represented and direct votes by the same principal must dedupe to one voter: #{result[:errors].inspect}"
  end

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
