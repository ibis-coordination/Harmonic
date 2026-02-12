# typed: true

class DecisionParticipant < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent
  before_validation :set_superagent_id
  belongs_to :decision
  belongs_to :user

  has_many :votes, dependent: :destroy
  has_many :options, dependent: :destroy

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(decision).tenant_id if tenant_id.nil?
  end

  sig { void }
  def set_superagent_id
    self.superagent_id = T.must(decision).superagent_id if superagent_id.nil?
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    response = {
      id: id,
      decision_id: decision_id,
      user_id: user_id,
      created_at: created_at,
    }
    if include.include?('votes')
      response.merge!({ votes: votes.map(&:api_json) })
    end
    response
  end

  sig { returns(T::Boolean) }
  def authenticated?
    # User is required, so participant is always authenticated
    true
  end

  sig { returns(T::Boolean) }
  def has_dependent_resources?
    votes.any? || options.any?
  end
end
