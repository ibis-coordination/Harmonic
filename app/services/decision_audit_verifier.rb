# typed: true

class DecisionAuditVerifier
  extend T::Sig

  sig { params(decision: Decision).returns(T::Hash[Symbol, T.untyped]) }
  def self.verify_chain(decision)
    entries = DecisionAuditEntry.where(decision_id: decision.id).order(:sequence_number).to_a
    errors = []
    previous_hash = T.let(nil, T.nilable(String))

    entries.each_with_index do |entry, index|
      expected_sequence = index + 1

      # Check sequence continuity
      if entry.sequence_number != expected_sequence
        errors << "Entry ##{entry.sequence_number}: sequence gap (expected #{expected_sequence})"
      end

      # Check chain link
      if entry.previous_hash != previous_hash
        errors << "Entry ##{entry.sequence_number}: chain link broken (previous_hash does not match prior entry)"
      end

      # Recompute and verify hash
      recomputed = DecisionAuditService.compute_hash(entry)
      if entry.entry_hash != recomputed
        errors << "Entry ##{entry.sequence_number}: hash mismatch (stored: #{entry.entry_hash[0..7]}..., computed: #{recomputed[0..7]}...)"
      end

      previous_hash = entry.entry_hash
    end

    # Check final chain hash if set on decision
    chain_hash = decision.audit_chain_hash
    if chain_hash.present? && entries.any?
      last_hash = entries.last&.entry_hash
      if chain_hash != last_hash
        errors << "Decision chain hash mismatch (stored: #{chain_hash[0..7]}..., last entry: #{last_hash&.slice(0, 8)}...)"
      end
    end

    {
      valid: errors.empty?,
      entry_count: entries.size,
      errors: errors,
      last_hash: entries.last&.entry_hash,
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
end
