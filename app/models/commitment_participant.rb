# typed: false

class CommitmentParticipant < ApplicationRecord
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :commitment
  belongs_to :user, optional: true

  def set_tenant_id
    self.tenant_id ||= commitment.tenant_id
  end

  def set_studio_id
    self.studio_id ||= commitment.studio_id
  end

  def api_json
    {
      id: id,
      commitment_id: commitment_id,
      user_id: user_id,
      committed_at: committed_at,
    }
  end

  def authenticated?
    # If there is a user association, then we know the participant is authenticated
    user.present?
  end

  def has_dependent_resources?
    false
  end

  def committed?
    committed_at.present?
  end

  def committed
    committed?
  end

  def committed=(value)
    if value == '1' || value == 'true' || value == true
      self.committed_at = Time.current unless committed?
    elsif value == '0' || value == 'false' || value == false
      self.committed_at = nil
    else
      raise 'Invalid value for committed'
    end
  end
end
