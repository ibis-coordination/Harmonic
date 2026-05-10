# typed: true

class DecisionAuditVerifier
  extend T::Sig

  sig { params(decision: Decision).returns(T::Hash[Symbol, T.untyped]) }
  def self.verify_chain(decision)
    entries = DecisionAuditEntry.where(decision_id: decision.id).order(:sequence_number).to_a
    errors = []
    binding_statuses = T.let({}, T::Hash[Integer, Symbol])
    previous_hash = T.let(nil, T.nilable(String))

    entries.each_with_index do |entry, index|
      expected_sequence = index + 1

      # Check sequence continuity
      errors << "Entry ##{entry.sequence_number}: sequence gap (expected #{expected_sequence})" if entry.sequence_number != expected_sequence

      # Check chain link
      if entry.previous_hash != previous_hash
        errors << "Entry ##{entry.sequence_number}: chain link broken (previous_hash does not match prior entry)"
      end

      # Recompute and verify hash
      recomputed = DecisionAuditService.compute_hash(entry)
      if entry.entry_hash != recomputed
        errors << "Entry ##{entry.sequence_number}: hash mismatch (stored: #{entry.entry_hash[0..7]}..., computed: #{recomputed[0..7]}...)"
      end

      # Per-entry actor-identity binding status (v2 only).
      # :verified / :unattributable / :tamper_or_scrub_inconsistent / :no_actor / :v1_chain_only
      binding_statuses[entry.sequence_number] = verify_actor_binding(entry)

      previous_hash = entry.entry_hash
    end

    # Check final chain hash if set on decision
    chain_hash = decision.audit_chain_hash
    if chain_hash.present? && entries.any?
      last_hash = entries.last&.entry_hash
      errors << "Decision chain hash mismatch (stored: #{chain_hash[0..7]}..., last entry: #{last_hash&.slice(0, 8)}...)" if chain_hash != last_hash
    end

    # Surface tamper detection from the binding check separately from chain
    # integrity. A scrubbed entry is expected and shouldn't fail the chain.
    binding_inconsistent = binding_statuses.values.count(:tamper_or_scrub_inconsistent)

    {
      valid: errors.empty? && binding_inconsistent.zero?,
      entry_count: entries.size,
      errors: errors,
      last_hash: entries.last&.entry_hash,
      binding_statuses: binding_statuses,
      binding_inconsistent_count: binding_inconsistent,
      scrubbed_count: binding_statuses.values.count(:unattributable),
    }
  end

  sig { params(entry: DecisionAuditEntry).returns(T::Hash[Symbol, T.untyped]) }
  def self.verify_entry(entry)
    recomputed = DecisionAuditService.compute_hash(entry)
    valid = entry.entry_hash == recomputed
    {
      valid: valid,
      stored_hash: entry.entry_hash,
      computed_hash: recomputed,
      error: valid ? nil : "hash mismatch",
    }
  end

  # Independent actor-identity binding check for v2 entries. The chain itself
  # proves that the stored actor_token wasn't silently changed (the token is
  # in the hashed content). This check additionally confirms the token actually
  # binds to the stored identity.
  #
  # Outcomes:
  #   :verified                       — token matches the recomputed derivation
  #   :unattributable                 — actor_id or actor_token_salt is NULL
  #                                     (PII has been scrubbed; intentional)
  #   :tamper_or_scrub_inconsistent   — derivation doesn't match stored token
  #                                     (either a tamper, or a partial scrub
  #                                     that left the chain inconsistent —
  #                                     cross-reference SecurityAuditLog)
  #   :no_actor                       — v2 entry has no actor (e.g., beacon_drawn)
  #   :v1_chain_only                  — entry is v1; binding is enforced by the
  #                                     chain hash itself rather than a separate
  #                                     token, so the binding check doesn't apply
  sig { params(entry: DecisionAuditEntry).returns(Symbol) }
  def self.verify_actor_binding(entry)
    return :v1_chain_only if entry.schema_version != 2
    return :no_actor if entry.actor_token.blank?
    return :unattributable if entry.actor_id.blank? || entry.actor_token_salt.blank?

    expected = Digest::SHA256.hexdigest(
      "#{entry.decision_id}|#{entry.actor_id}|#{entry.actor_handle}|#{entry.actor_token_salt}"
    )
    expected == entry.actor_token ? :verified : :tamper_or_scrub_inconsistent
  end

  sig { params(decision: Decision).returns(T::Hash[Symbol, T.untyped]) }
  def self.verify_vote_tallies(decision)
    has_votes = decision.votes.any?
    unless has_votes
      return { valid: true, skipped: true, errors: ["No votes have been cast yet — vote tally verification will be available after voting begins."] }
    end

    totals = replay_vote_totals(decision)
    errors = T.let([], T::Array[String])

    decision.results.each do |result|
      title = T.must(result.option_title)
      expected = totals[title] || { accepted: 0, preferred: 0 }
      if result.accepted_yes != expected[:accepted]
        errors << "'#{title}' acceptance count is #{result.accepted_yes}, audit chain shows #{expected[:accepted]}"
      end
      if result.preferred != expected[:preferred]
        errors << "'#{title}' preference count is #{result.preferred}, audit chain shows #{expected[:preferred]}"
      end
    end

    { valid: errors.empty?, skipped: false, errors: errors }
  end

  sig { params(decision: Decision).returns(T::Hash[String, { accepted: Integer, preferred: Integer }]) }
  def self.replay_vote_totals(decision)
    entries = DecisionAuditEntry.where(decision_id: decision.id)
      .where(action: ["vote_cast", "vote_updated"])
      .order(:sequence_number)
      .to_a

    # Replay votes: keep latest per (actor, option_title) pair.
    # For v2 entries, dedupe by actor_token (actor_id may be NULL post-scrub).
    # For v1, dedupe by actor_id.
    votes = T.let({}, T::Hash[[String, String], { accepted: Integer, preferred: Integer }])
    entries.each do |entry|
      actor_key = entry.schema_version == 2 ? (entry.actor_token || "") : (entry.actor_id || "")
      votes[[actor_key, entry.option_title || ""]] = {
        accepted: entry.accepted || 0,
        preferred: entry.preferred || 0,
      }
    end

    # Sum totals per option
    totals = T.let({}, T::Hash[String, { accepted: Integer, preferred: Integer }])
    votes.each do |(_, option_title), vote_data|
      totals[option_title] ||= { accepted: 0, preferred: 0 }
      total = T.must(totals[option_title])
      total[:accepted] += vote_data[:accepted]
      total[:preferred] += vote_data[:preferred]
    end
    totals
  end
  private_class_method :replay_vote_totals

  sig { params(decision: Decision, fetched_randomness: T.nilable(String)).returns(T::Hash[Symbol, T.untyped]) }
  def self.verify_beacon(decision, fetched_randomness:)
    errors = T.let([], T::Array[String])

    # No beacon drawn yet
    if decision.lottery_beacon_round.blank?
      return { valid: true, skipped: true, errors: ["No beacon drawn yet — beacon verification will be available after the decision closes."] }
    end

    # Verify round derivation
    deadline = decision.deadline
    if deadline.present?
      expected_round = RandomnessProvider.current.round_for_timestamp(deadline)
      actual_round = decision.lottery_beacon_round
      errors << "Server claims round #{actual_round}, deadline implies round #{expected_round}" if actual_round != expected_round
    end

    # Can't verify randomness or sort keys without fetched randomness
    if fetched_randomness.blank?
      return {
        valid: true,
        skipped: true,
        errors: ["Could not fetch randomness from drand to verify sort keys."],
      }
    end

    # Verify randomness matches
    stored_randomness = decision.lottery_beacon_randomness
    if stored_randomness != fetched_randomness
      errors << "Beacon randomness does not match: server says #{stored_randomness}, fetched #{fetched_randomness}"
    end

    # Verify sort keys
    decision.results.each do |result|
      next if result.lottery_sort_key.blank?

      normalized_title = T.must(result.option_title).unicode_normalize(:nfc)
      computed = Digest::SHA256.hexdigest(fetched_randomness + normalized_title)
      errors << "Sort key mismatch for '#{result.option_title}'" if computed != result.lottery_sort_key
    end

    { valid: errors.empty?, skipped: false, errors: errors }
  end

  sig { params(decision: Decision, fetched_randomness: T.nilable(String)).returns(T::Hash[Symbol, T.untyped]) }
  def self.verify_all(decision, fetched_randomness: nil)
    chain = verify_chain(decision)
    vote_tallies = verify_vote_tallies(decision)
    beacon = verify_beacon(decision, fetched_randomness: fetched_randomness)

    {
      valid: chain[:valid] && vote_tallies[:valid] && beacon[:valid],
      chain: chain,
      vote_tallies: vote_tallies,
      beacon: beacon,
    }
  end
end
