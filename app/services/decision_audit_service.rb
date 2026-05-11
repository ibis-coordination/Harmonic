# typed: true

# Records audit entries for decision lifecycle events.
#
# == Metadata PII constraint
#
# `metadata` is a free-form jsonb column on `DecisionAuditEntry`. PII scrubbing
# only NULLs `actor_id`, `actor_handle`, and `actor_token_salt` — it does NOT
# touch `metadata`. Therefore, **callers of record_* must not put actor-
# identifying information into metadata**: no display names, emails, handles,
# personal pronouns, or anything that could re-identify the actor.
#
# Decision-content fields (question, description, option titles, deadlines)
# ARE acceptable in metadata — they are content the actor authored about the
# decision, not identifiers of the actor themselves. Scrubbing the actor's
# identity preserves the content of decisions they participated in, by design.
#
# All current call sites have been audited and are clean: metadata only ever
# contains decision attributes or system values (e.g., beacon round/randomness).
# `audit_chain_metadata_pii_test.rb` pins this shape against future drift.
class DecisionAuditService
  extend T::Sig

  sig { params(decision: Decision, actor: User).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_creation!(decision:, actor:)
    return nil if DecisionAuditEntry.where(decision_id: decision.id, action: "decision_created").exists?

    initial_values = {
      question: decision.question,
      description: decision.description,
      subtype: decision.subtype,
      deadline: decision.deadline&.iso8601,
      options_open: decision.options_open.to_s,
    }
    initial_values[:decision_maker_id] = decision.decision_maker_id if decision.decision_maker_id.present?
    record!(
      decision: decision,
      action: "decision_created",
      actor_id: actor.id,
      actor_handle: actor.handle,
      metadata: initial_values
    )
  end

  sig { params(decision: Decision, actor: User, changes: T::Hash[T.any(String, Symbol), T.untyped]).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_update!(decision:, actor:, changes:)
    record!(
      decision: decision,
      action: "decision_updated",
      actor_id: actor.id,
      actor_handle: actor.handle,
      metadata: changes
    )
  end

  sig { params(decision: Decision, option: Option, actor: User, old_title: String, new_title: String).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_option_update!(decision:, option:, actor:, old_title:, new_title:)
    record!(
      decision: decision,
      action: "option_updated",
      actor_id: actor.id,
      actor_handle: actor.handle,
      option_title: new_title,
      metadata: { old_title: old_title, new_title: new_title }
    )
  end

  sig { params(decision: Decision, vote: Vote, actor: User, is_update: T::Boolean).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_vote!(decision:, vote:, actor:, is_update: false)
    record!(
      decision: decision,
      action: is_update ? "vote_updated" : "vote_cast",
      actor_id: actor.id,
      actor_handle: actor.handle,
      option_title: T.must(vote.option).title,
      accepted: vote.accepted,
      preferred: vote.preferred
    )
  end

  sig { params(decision: Decision, option: Option, actor: User, action: String).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_option!(decision:, option:, actor:, action:)
    record!(
      decision: decision,
      action: action,
      actor_id: actor.id,
      actor_handle: actor.handle,
      option_title: option.title
    )
  end

  sig { params(decision: Decision, actor: User).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_close!(decision:, actor:)
    return nil if DecisionAuditEntry.where(decision_id: decision.id, action: "decision_closed").exists?

    record!(
      decision: decision,
      action: "decision_closed",
      actor_id: actor.id,
      actor_handle: actor.handle
    )
  end

  sig { params(decision: Decision, round: Integer, randomness: String).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_beacon!(decision:, round:, randomness:)
    return nil if DecisionAuditEntry.where(decision_id: decision.id, action: "beacon_drawn").exists?

    record!(
      decision: decision,
      action: "beacon_drawn",
      metadata: { round: round, randomness: randomness }
    )
  end

  sig { params(entry: DecisionAuditEntry).returns(String) }
  def self.compute_hash(entry)
    case entry.schema_version
    when 1 then compute_hash_v1(entry)
    when 2 then compute_hash_v2(entry)
    else raise "Unknown schema version: #{entry.schema_version}"
    end
  end

  sig { params(entry: DecisionAuditEntry).returns(String) }
  def self.hash_input(entry)
    case entry.schema_version
    when 1 then hash_input_v1(entry)
    when 2 then hash_input_v2(entry)
    else raise "Unknown schema version: #{entry.schema_version}"
    end
  end

  # Derives the per-entry actor token. The salt is destroyed on PII scrub, which
  # makes brute-force re-identification computationally infeasible. The token
  # itself is in the chain hash, so tampering with actor_id or actor_handle (without
  # also recomputing the token, which requires knowing the original salt) is
  # detectable by `verify_actor_binding`.
  sig { params(decision_id: String, actor_id: String, actor_handle: String, salt: String).returns(String) }
  def self.derive_actor_token(decision_id:, actor_id:, actor_handle:, salt:)
    Digest::SHA256.hexdigest("#{decision_id}|#{actor_id}|#{actor_handle}|#{salt}")
  end

  sig do
    params(
      decision: Decision,
      action: String,
      actor_id: T.nilable(String),
      actor_handle: T.nilable(String),
      option_title: T.nilable(String),
      accepted: T.nilable(Integer),
      preferred: T.nilable(Integer),
      metadata: T.nilable(T::Hash[T.any(String, Symbol), T.untyped])
    ).returns(T.nilable(DecisionAuditEntry))
  end
  def self.record!(decision:, action:, actor_id: nil, actor_handle: nil, option_title: nil, accepted: nil, preferred: nil, metadata: nil)
    return nil unless decision.audit_chain_enabled?

    retries = 0
    begin
      ActiveRecord::Base.transaction(requires_new: true) do
        decision.lock!

        last_entry = DecisionAuditEntry.where(decision_id: decision.id).order(:sequence_number).last
        sequence_number = (last_entry&.sequence_number || 0) + 1
        previous_hash = last_entry&.entry_hash

        now = Time.current.change(usec: 0)

        # For v2: derive the actor token from (decision_id, actor_id, actor_handle, salt).
        # All NULL when there's no actor (e.g., beacon_drawn).
        #
        # Both the salt AND the actor_handle are anchored to the participant's
        # FIRST entry in this decision: we look up the first prior entry by
        # (decision_id, actor_id) and reuse its salt and actor_handle. This
        # gives us a stable actor_token per (decision_id, actor_id) regardless
        # of whether the participant renames between actions — vote-tally
        # dedupe (which keys on actor_token) stays correct, and scrubbing a
        # user's salt destroys identity binding for all their entries in one
        # bulk update on account closure. The stored actor_handle is also the
        # anchor handle, not the current one, so the binding check (which
        # recomputes using entry.actor_handle) stays per-entry self-contained.
        actor_token_salt = nil
        actor_token = nil
        anchor_handle = actor_handle
        if actor_id
          prior_entry = DecisionAuditEntry
            .where(decision_id: decision.id, actor_id: actor_id)
            .where.not(actor_token_salt: nil)
            .order(:sequence_number)
            .first
          actor_token_salt = prior_entry&.actor_token_salt || SecureRandom.hex(32)
          anchor_handle    = prior_entry&.actor_handle     || actor_handle
          actor_token = derive_actor_token(
            decision_id: decision.id,
            actor_id: actor_id,
            actor_handle: anchor_handle.to_s,
            salt: actor_token_salt
          )
        end

        entry = DecisionAuditEntry.new(
          tenant_id: decision.tenant_id,
          collective_id: decision.collective_id,
          decision: decision,
          sequence_number: sequence_number,
          schema_version: DecisionAuditEntry::CURRENT_SCHEMA_VERSION,
          action: action,
          actor_id: actor_id,
          actor_handle: anchor_handle,
          actor_token: actor_token,
          actor_token_salt: actor_token_salt,
          option_title: option_title,
          accepted: accepted,
          preferred: preferred,
          metadata: metadata&.transform_keys(&:to_s),
          previous_hash: previous_hash,
          created_at: now
        )

        entry.entry_hash = compute_hash(entry)
        entry.save!
        entry
      end
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
      retries += 1
      raise if retries > 3

      sleep(0.1 * retries)
      retry
    end
  end

  sig { params(entry: DecisionAuditEntry).returns(String) }
  def self.compute_hash_v1(entry)
    Digest::SHA256.hexdigest(hash_input_v1(entry))
  end

  sig { params(entry: DecisionAuditEntry).returns(String) }
  def self.hash_input_v1(entry)
    title = entry.option_title
    normalized_title = title.nil? ? "" : title.unicode_normalize(:nfc)
    sorted_metadata = entry.metadata ? JSON.generate(entry.metadata.sort.to_h) : ""

    [
      "v1",
      entry.previous_hash || "",
      entry.sequence_number.to_s,
      entry.action,
      entry.actor_id || "",
      entry.actor_handle || "",
      normalized_title,
      entry.accepted.nil? ? "" : entry.accepted.to_s,
      entry.preferred.nil? ? "" : entry.preferred.to_s,
      sorted_metadata,
      entry.created_at.iso8601,
    ].join("|")
  end

  # v2 hash content excludes actor_id and actor_handle directly. Actor identity
  # is bound via actor_token = SHA256(decision_id || actor_id || actor_handle || salt).
  # actor_token_salt is intentionally NOT in the hashed content — it must be
  # destroyable on PII scrub without invalidating the chain.
  sig { params(entry: DecisionAuditEntry).returns(String) }
  def self.compute_hash_v2(entry)
    Digest::SHA256.hexdigest(hash_input_v2(entry))
  end

  sig { params(entry: DecisionAuditEntry).returns(String) }
  def self.hash_input_v2(entry)
    title = entry.option_title
    normalized_title = title.nil? ? "" : title.unicode_normalize(:nfc)
    sorted_metadata = entry.metadata ? JSON.generate(entry.metadata.sort.to_h) : ""

    [
      "v2",
      entry.previous_hash || "",
      entry.sequence_number.to_s,
      entry.action,
      entry.actor_token || "",
      normalized_title,
      entry.accepted.nil? ? "" : entry.accepted.to_s,
      entry.preferred.nil? ? "" : entry.preferred.to_s,
      sorted_metadata,
      entry.created_at.iso8601,
    ].join("|")
  end

  private_class_method :record!, :compute_hash_v1, :hash_input_v1, :compute_hash_v2, :hash_input_v2
end
