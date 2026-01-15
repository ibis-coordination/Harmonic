# typed: true

class Vote < ApplicationRecord
  extend T::Sig

  include Tracked
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent
  before_validation :set_superagent_id
  belongs_to :option
  belongs_to :decision
  belongs_to :decision_participant

  validates :accepted, inclusion: { in: [0, 1] }
  validates :preferred, inclusion: { in: [0, 1] }

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(option).tenant_id if tenant_id.nil?
  end

  sig { void }
  def set_superagent_id
    self.superagent_id = T.must(option).superagent_id if superagent_id.nil?
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    {
      id: id,
      option_id: option_id,
      decision_id: decision_id,
      decision_participant_id: decision_participant_id,
      accepted: accepted,
      preferred: preferred,
      created_at: created_at,
      updated_at: updated_at,
    }
  end
end
