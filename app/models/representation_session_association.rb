# typed: false

class RepresentationSessionAssociation < ApplicationRecord
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :representation_session
  belongs_to :resource, polymorphic: true
  belongs_to :resource_studio, class_name: 'Studio'

  validate :resource_studio_matches_resource
  validates :resource_type, inclusion: { in: %w[Heartbeat Note Decision Commitment NoteHistoryEvent Option Approval CommitmentParticipant] }

  def set_tenant_id
    self.tenant_id = representation_session.tenant_id
  end

  def set_studio_id
    self.studio_id = representation_session.studio_id
  end

  def resource_studio_matches_resource
    return if resource_studio_id == resource.studio_id
    errors.add(:resource_studio, "must match resource's studio")
  end

end