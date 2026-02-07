# typed: true

class RepresentationSessionAssociation < ApplicationRecord
  extend T::Sig
  include MightNotBelongToSuperagent

  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent, optional: true
  before_validation :set_superagent_id
  belongs_to :representation_session
  belongs_to :resource, polymorphic: true
  belongs_to :resource_superagent, class_name: 'Superagent'

  validate :resource_superagent_matches_resource
  validates :resource_type, inclusion: { in: %w[Heartbeat Note Decision Commitment NoteHistoryEvent Option Vote CommitmentParticipant] }

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(representation_session).tenant_id
  end

  sig { void }
  def set_superagent_id
    # Inherits superagent_id from the session (NULL for user representation, studio ID for studio representation)
    self.superagent_id = T.must(representation_session).superagent_id
  end

  sig { void }
  def resource_superagent_matches_resource
    return if resource_superagent_id == T.unsafe(resource).superagent_id
    errors.add(:resource_superagent, "must match resource's superagent")
  end

end