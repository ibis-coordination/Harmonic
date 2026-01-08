# typed: true

class DecisionParticipant < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :decision
  belongs_to :user, optional: true

  has_many :approvals, dependent: :destroy
  has_many :options, dependent: :destroy

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(decision).tenant_id if tenant_id.nil?
  end

  sig { void }
  def set_studio_id
    self.studio_id = T.must(decision).studio_id if studio_id.nil?
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    response = {
      id: id,
      decision_id: decision_id,
      user_id: user_id,
      created_at: created_at,
    }
    if include.include?('approvals')
      response.merge!({ approvals: approvals.map(&:api_json) })
    end
    response
  end

  sig { returns(T::Boolean) }
  def authenticated?
    # If there is a user association, then we know the participant is authenticated
    user.present?
  end

  sig { returns(T::Boolean) }
  def has_dependent_resources?
    approvals.any? || options.any?
  end
end
