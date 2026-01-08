# typed: false

class DecisionParticipant < ApplicationRecord
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :decision
  belongs_to :user, optional: true

  has_many :approvals, dependent: :destroy
  has_many :options, dependent: :destroy

  def set_tenant_id
    self.tenant_id ||= decision.tenant_id
  end

  def set_studio_id
    self.studio_id ||= decision.studio_id
  end

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

  def authenticated?
    # If there is a user association, then we know the participant is authenticated
    user.present?
  end

  def has_dependent_resources?
    approvals.any? || options.any?
  end
end
