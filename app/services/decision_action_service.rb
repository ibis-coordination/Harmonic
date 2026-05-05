# typed: true

# Chokepoint for all audited decision mutations.
# All vote, option, close, and beacon operations must go through this service
# to ensure mutations and audit entries are recorded in the same transaction.
class DecisionActionService
  extend T::Sig

  sig do
    params(
      decision: Decision,
      vote: Vote,
      actor: User,
      is_update: T::Boolean,
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.cast_vote!(decision:, vote:, actor:, is_update: false)
    ActiveRecord::Base.transaction do
      vote.save!
      audit_entry = DecisionAuditService.record_vote!(
        decision: decision, vote: vote, actor: actor, is_update: is_update,
      )
      { vote: vote, audit_entry: audit_entry }
    end
  end

  sig do
    params(
      decision: Decision,
      option: Option,
      actor: User,
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.add_option!(decision:, option:, actor:)
    ActiveRecord::Base.transaction do
      option.save!
      audit_entry = DecisionAuditService.record_option!(
        decision: decision, option: option, actor: actor, action: "option_added",
      )
      { option: option, audit_entry: audit_entry }
    end
  end

  sig do
    params(
      decision: Decision,
      option: Option,
      actor: User,
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.remove_option!(decision:, option:, actor:)
    ActiveRecord::Base.transaction do
      audit_entry = DecisionAuditService.record_option!(
        decision: decision, option: option, actor: actor, action: "option_removed",
      )
      option.destroy!
      { audit_entry: audit_entry }
    end
  end

  sig do
    params(
      decision: Decision,
      actor: User,
      executive_selections: T.nilable(T::Array[String]),
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def self.close_decision!(decision:, actor:, executive_selections: nil)
    ActiveRecord::Base.transaction do
      decision.update!(deadline: Time.current)
      close_entry = DecisionAuditService.record_close!(decision: decision, actor: actor)

      if executive_selections
        selection_entry = DecisionAuditService.record_executive_selection!(
          decision: decision, actor: actor, selected_option_titles: executive_selections,
        )
        last_entry = selection_entry
      else
        last_entry = close_entry
      end

      if decision.is_executive? && last_entry
        decision.update!(audit_chain_hash: last_entry.entry_hash)
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
