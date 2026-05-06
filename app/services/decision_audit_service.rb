# typed: true

class DecisionAuditService
  extend T::Sig

  sig { params(decision: Decision, actor: User).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_creation!(decision:, actor:)
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
      metadata: initial_values,
    )
  end

  sig { params(decision: Decision, actor: User, changes: T::Hash[T.any(String, Symbol), T.untyped]).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_update!(decision:, actor:, changes:)
    record!(
      decision: decision,
      action: "decision_updated",
      actor_id: actor.id,
      actor_handle: actor.handle,
      metadata: changes,
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
      metadata: { old_title: old_title, new_title: new_title },
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
      preferred: vote.preferred,
    )
  end

  sig { params(decision: Decision, option: Option, actor: User, action: String).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_option!(decision:, option:, actor:, action:)
    record!(
      decision: decision,
      action: action,
      actor_id: actor.id,
      actor_handle: actor.handle,
      option_title: option.title,
    )
  end

  sig { params(decision: Decision, actor: User).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_close!(decision:, actor:)
    record!(
      decision: decision,
      action: "decision_closed",
      actor_id: actor.id,
      actor_handle: actor.handle,
    )
  end

  sig { params(decision: Decision, actor: User, selected_option_titles: T::Array[String]).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_executive_selection!(decision:, actor:, selected_option_titles:)
    record!(
      decision: decision,
      action: "executive_selection",
      actor_id: actor.id,
      actor_handle: actor.handle,
      metadata: { selected_option_titles: selected_option_titles },
    )
  end

  sig { params(decision: Decision, round: Integer, randomness: String).returns(T.nilable(DecisionAuditEntry)) }
  def self.record_beacon!(decision:, round:, randomness:)
    record!(
      decision: decision,
      action: "beacon_drawn",
      metadata: { round: round, randomness: randomness },
    )
  end

  sig { params(entry: DecisionAuditEntry).returns(String) }
  def self.compute_hash(entry)
    case entry.schema_version
    when 1 then compute_hash_v1(entry)
    else raise "Unknown schema version: #{entry.schema_version}"
    end
  end

  sig { params(entry: DecisionAuditEntry).returns(String) }
  def self.hash_input(entry)
    case entry.schema_version
    when 1 then hash_input_v1(entry)
    else raise "Unknown schema version: #{entry.schema_version}"
    end
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
      metadata: T.nilable(T::Hash[T.any(String, Symbol), T.untyped]),
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

        now = Time.current

        entry = DecisionAuditEntry.new(
          tenant_id: decision.tenant_id,
          collective_id: decision.collective_id,
          decision: decision,
          sequence_number: sequence_number,
          schema_version: DecisionAuditEntry::CURRENT_SCHEMA_VERSION,
          action: action,
          actor_id: actor_id,
          actor_handle: actor_handle,
          option_title: option_title,
          accepted: accepted,
          preferred: preferred,
          metadata: metadata&.transform_keys(&:to_s),
          previous_hash: previous_hash,
          created_at: now,
        )

        entry.entry_hash = compute_hash(entry)
        entry.save!
        entry
      end
    rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => e
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

  private_class_method :record!, :compute_hash_v1, :hash_input_v1
end
