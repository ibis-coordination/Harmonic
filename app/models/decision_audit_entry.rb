# typed: true

class DecisionAuditEntry < ApplicationRecord
  extend T::Sig

  include CollectiveIdMatchesParent

  ACTIONS = %w[decision_created decision_updated option_added option_removed option_updated vote_cast vote_updated decision_closed beacon_drawn].freeze
  CURRENT_SCHEMA_VERSION = 3

  self.implicit_order_column = "sequence_number"

  belongs_to :tenant
  belongs_to :collective
  belongs_to :decision
  collective_id_matches :decision

  validates :action, inclusion: { in: ACTIONS }
  validates :schema_version, inclusion: { in: [1, 2, 3] }
  validates :representation_kind, inclusion: { in: %w[user collective] }, allow_nil: true
  validates :sequence_number, presence: true
  validates :entry_hash, presence: true

  sig { params(decision: Decision, user: User).returns(T.nilable(DecisionAuditEntry)) }
  def self.receipt_for_user(decision, user)
    where(decision_id: decision.id, actor_id: user.id).order(:sequence_number).last
  end

  # PII scrub for account closure. Nulls the identity columns the immutability
  # trigger designates as mutable — chain hashes are untouched, so the chain
  # stays verifiable and scrubbed entries verify as :unattributable.
  sig { params(user: User).returns(Integer) }
  def self.scrub_identity_for!(user)
    as_actor = unscoped.where(actor_id: user.id) # unscoped-allowed - PII scrub of the user's own identity across tenants
      .update_all(actor_id: nil, actor_handle: nil, actor_token_salt: nil)
    as_representative = unscoped.where(representative_id: user.id) # unscoped-allowed - PII scrub of the user's own identity across tenants
      .update_all(representative_id: nil, representative_handle: nil, representative_token_salt: nil)
    as_actor + as_representative
  end

  sig { params(decision: Decision, receipt_hash: String).returns(T.nilable(DecisionAuditEntry)) }
  def self.find_by_receipt(decision, receipt_hash)
    find_by(decision_id: decision.id, entry_hash: receipt_hash)
  end
end
