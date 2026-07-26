# typed: true

# Chokepoint for all audited decision mutations.
# All vote, option, close, and beacon operations must go through this service
# to ensure mutations and audit entries are recorded in the same transaction.
class DecisionActionService
  extend T::Sig

  sig do
    params(
      decision: Decision,
      actor: User,
      representation_session: T.nilable(RepresentationSession),
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.create_decision!(decision:, actor:, representation_session: nil)
    ActiveRecord::Base.transaction do
      decision.save!
      audit_entry = DecisionAuditService.record_creation!(decision: decision, actor: actor, representation_session: representation_session)
      { decision: decision, audit_entry: audit_entry }
    end
  end

  # Audit metadata holds strings. Structured columns (the eligibility rules)
  # have to be JSON-encoded rather than stringified — `to_s` on a Hash yields a
  # Ruby literal ({"any_of"=>[...]}), which is not machine-readable and would
  # make the audit record of an electorate change useless to anything but a
  # human squinting at it.
  sig { params(value: T.untyped).returns(T.nilable(String)) }
  def self.audit_value(value)
    case value
    when Time then value.iso8601
    when Hash, Array then value.to_json
    else value&.to_s
    end
  end

  sig do
    params(
      decision: Decision,
      actor: User,
      representation_session: T.nilable(RepresentationSession),
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.update_decision!(decision:, actor:, representation_session: nil)
    ActiveRecord::Base.transaction do
      changes = decision.changes.except("updated_at").transform_values do |v|
        v.map { |val| audit_value(val) }
      end
      decision.save!
      audit_entry = if changes.any?
        DecisionAuditService.record_update!(decision: decision, actor: actor, changes: changes, representation_session: representation_session)
      end
      { decision: decision, audit_entry: audit_entry }
    end
  end

  sig do
    params(
      option: Option,
      actor: User,
      representation_session: T.nilable(RepresentationSession),
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.update_option!(option:, actor:, representation_session: nil)
    ActiveRecord::Base.transaction do
      old_title = option.title_was
      option.save!
      audit_entry = if option.title != old_title && old_title.present?
        DecisionAuditService.record_option_update!(
          decision: T.must(option.decision), option: option, actor: actor,
          old_title: old_title, new_title: option.title,
          representation_session: representation_session,
        )
      end
      { option: option, audit_entry: audit_entry }
    end
  end

  sig do
    params(
      decision: Decision,
      vote: Vote,
      actor: User,
      is_update: T::Boolean,
      representation_session: T.nilable(RepresentationSession),
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.cast_vote!(decision:, vote:, actor:, is_update: false, representation_session: nil)
    # Eligibility follows the participant's user, not `actor` — a trustee voting
    # on someone's behalf is judged against the represented user's standing, and
    # the REST path can target a participant directly. Only `vote` decisions are
    # gated: executive closes write votes as the decision maker through
    # ApiHelper#create_executive_selections!, and lottery decisions take no votes.
    if decision.is_vote? && !decision.eligible_voter?(vote.decision_participant&.user)
      raise ArgumentError, "You are not eligible to vote on this decision."
    end

    ActiveRecord::Base.transaction do
      vote.save!
      audit_entry = DecisionAuditService.record_vote!(
        decision: decision, vote: vote, actor: actor, is_update: is_update,
        representation_session: representation_session,
      )
      vote.audit_receipt = audit_entry&.entry_hash
      { vote: vote, audit_entry: audit_entry }
    end
  end

  sig do
    params(
      decision: Decision,
      option: Option,
      actor: User,
      representation_session: T.nilable(RepresentationSession),
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.add_option!(decision:, option:, actor:, representation_session: nil)
    ActiveRecord::Base.transaction do
      option.save!
      audit_entry = DecisionAuditService.record_option!(
        decision: decision, option: option, actor: actor, action: "option_added",
        representation_session: representation_session,
      )
      { option: option, audit_entry: audit_entry }
    end
  end

  sig do
    params(
      decision: Decision,
      option: Option,
      actor: User,
      representation_session: T.nilable(RepresentationSession),
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.remove_option!(decision:, option:, actor:, representation_session: nil)
    ActiveRecord::Base.transaction do
      audit_entry = DecisionAuditService.record_option!(
        decision: decision, option: option, actor: actor, action: "option_removed",
        representation_session: representation_session,
      )
      option.destroy!
      { audit_entry: audit_entry }
    end
  end

  sig do
    params(
      decision: Decision,
      actor: User,
      representation_session: T.nilable(RepresentationSession),
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.close_decision!(decision:, actor:, representation_session: nil)
    ActiveRecord::Base.transaction do
      decision.update!(deadline: Time.current)
      close_entry = DecisionAuditService.record_close!(decision: decision, actor: actor, representation_session: representation_session)

      if decision.is_executive? && close_entry
        decision.update!(audit_chain_hash: close_entry.entry_hash)
      end

      { audit_entry: close_entry }
    end
  end

  sig do
    params(
      decision: Decision,
      round: Integer,
      randomness: String,
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.draw_beacon!(decision:, round:, randomness:)
    return { audit_entry: nil } if decision.beacon_drawn?

    ActiveRecord::Base.transaction do
      decision.update!(lottery_beacon_round: round, lottery_beacon_randomness: randomness)
      entry = DecisionAuditService.record_beacon!(
        decision: decision, round: round, randomness: randomness,
      )
      decision.update!(audit_chain_hash: entry.entry_hash) if entry
      { audit_entry: entry }
    end
  end
end
