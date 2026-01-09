# typed: true

class RepresentationSessionAssociation < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :representation_session
  belongs_to :resource, polymorphic: true
  belongs_to :resource_studio, class_name: 'Studio'

  validate :resource_studio_matches_resource
  validates :resource_type, inclusion: { in: %w[Heartbeat Note Decision Commitment NoteHistoryEvent Option Vote CommitmentParticipant] }

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(representation_session).tenant_id
  end

  sig { void }
  def set_studio_id
    self.studio_id = T.must(representation_session).studio_id
  end

  sig { void }
  def resource_studio_matches_resource
    return if resource_studio_id == T.unsafe(resource).studio_id
    errors.add(:resource_studio, "must match resource's studio")
  end

end