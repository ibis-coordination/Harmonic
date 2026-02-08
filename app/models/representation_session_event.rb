# typed: true

class RepresentationSessionEvent < ApplicationRecord
  extend T::Sig
  include MightNotBelongToSuperagent

  belongs_to :tenant
  belongs_to :superagent, optional: true
  belongs_to :representation_session
  belongs_to :resource, polymorphic: true
  belongs_to :context_resource, polymorphic: true, optional: true
  belongs_to :resource_superagent, class_name: "Superagent"

  VALID_RESOURCE_TYPES = %w[
    Note Decision Commitment Heartbeat
    NoteHistoryEvent Option Vote CommitmentParticipant
  ].freeze

  VALID_CONTEXT_RESOURCE_TYPES = %w[Note Decision Commitment].freeze

  validates :action_name, presence: true
  validates :resource_type, inclusion: { in: VALID_RESOURCE_TYPES }
  validates :context_resource_type, inclusion: { in: VALID_CONTEXT_RESOURCE_TYPES }, allow_nil: true

  before_validation :set_tenant_id
  before_validation :set_superagent_id

  sig { void }
  def set_tenant_id
    return if tenant_id.present?

    self.tenant_id = T.must(representation_session&.tenant_id)
  end

  sig { void }
  def set_superagent_id
    return if superagent_id.present?

    self.superagent_id = representation_session&.superagent_id
  end

  # Class method to find the creation event for a resource
  sig { params(resource: T.untyped, action_name: String).returns(T.nilable(RepresentationSessionEvent)) }
  def self.creation_event_for(resource, action_name)
    find_by(
      resource_type: resource.class.name,
      resource_id: resource.id,
      action_name: action_name
    )
  end

  # Human-readable verb phrase for activity log
  sig { returns(String) }
  def verb_phrase
    case action_name
    when /^create_/ then "created"
    when "confirm_read" then "confirmed reading"
    when "add_options" then "added options to"
    when "add_comment" then "commented on"
    when "vote" then "voted on"
    when "join_commitment" then "joined"
    when "send_heartbeat" then "sent heartbeat in"
    when /^update_/ then "updated"
    when /^pin_/ then "pinned"
    when /^unpin_/ then "unpinned"
    else action_name.humanize.downcase
    end
  end
end
