# typed: false

class Approval < ApplicationRecord
  include Tracked
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :option
  belongs_to :decision
  belongs_to :decision_participant

  validates :value, inclusion: { in: [0, 1] }
  validates :stars, inclusion: { in: [0, 1] }

  def set_tenant_id
    self.tenant_id ||= option.tenant_id
  end

  def set_studio_id
    self.studio_id ||= option.studio_id
  end

  def api_json(include: [])
    {
      id: id,
      option_id: option_id,
      decision_id: decision_id,
      decision_participant_id: decision_participant_id,
      value: value,
      stars: stars,
      created_at: created_at,
      updated_at: updated_at,
    }
  end
end
