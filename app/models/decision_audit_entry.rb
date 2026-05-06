# typed: true

class DecisionAuditEntry < ApplicationRecord
  extend T::Sig

  ACTIONS = %w[option_added option_removed vote_cast vote_updated executive_selection decision_closed beacon_drawn].freeze
  CURRENT_SCHEMA_VERSION = 1

  self.implicit_order_column = "sequence_number"

  belongs_to :tenant
  belongs_to :collective
  belongs_to :decision

  validates :action, inclusion: { in: ACTIONS }
  validates :schema_version, presence: true
  validates :sequence_number, presence: true
  validates :entry_hash, presence: true

  sig { params(decision: Decision, user: User).returns(T.nilable(DecisionAuditEntry)) }
  def self.receipt_for_user(decision, user)
    where(decision_id: decision.id, actor_id: user.id).order(:sequence_number).last
  end
end
