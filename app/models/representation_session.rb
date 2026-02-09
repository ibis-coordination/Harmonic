# typed: true

class RepresentationSession < ApplicationRecord
  extend T::Sig

  include Linkable
  include Commentable
  include HasTruncatedId
  include MightNotBelongToSuperagent

  belongs_to :tenant
  belongs_to :superagent, optional: true
  belongs_to :representative_user, class_name: "User"
  belongs_to :trustee_grant, optional: true
  has_many :representation_session_events, dependent: :destroy

  validates :began_at, presence: true
  validates :confirmed_understanding, inclusion: { in: [true] }
  validate :superagent_presence_matches_session_type

  # Studio representation requires superagent_id; user representation must NOT have superagent_id
  sig { void }
  def superagent_presence_matches_session_type
    if trustee_grant_id.present? && superagent_id.present?
      errors.add(:superagent_id, "must be nil for user representation sessions")
    elsif trustee_grant_id.nil? && superagent_id.nil?
      errors.add(:superagent_id, "is required for studio representation sessions")
    end
  end

  sig { void }
  def parse_and_create_link_records!
    # This method is overriding the method in the Linkable module
    # because the RepresentationSession model does not have a text field
    # but it can have backlinks from other models.
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def api_json
    {
      id: id,
      confirmed_understanding: confirmed_understanding,
      began_at: began_at,
      ended_at: ended_at,
      elapsed_time: elapsed_time,
      superagent_id: superagent_id,
      representative_user_id: representative_user_id,
      effective_user_id: effective_user.id,
    }
  end

  sig { void }
  def begin!
    # TODO: - add a check for active representation session
    raise "Must confirm understanding" unless confirmed_understanding

    # TODO: - add more validations
    self.began_at = T.cast(Time.current, ActiveSupport::TimeWithZone) if began_at.nil?
    save!
  end

  sig { returns(T::Boolean) }
  def active?
    ended_at.nil?
  end

  sig { returns(Float) }
  def elapsed_time
    return T.must(ended_at) - T.must(began_at) if ended_at

    Time.current - T.must(began_at)
  end

  sig { void }
  def end!
    return if ended?

    self.ended_at = T.cast(Time.current, ActiveSupport::TimeWithZone)
    save!
  end

  sig { returns(T::Boolean) }
  def ended?
    ended_at.present?
  end

  sig { returns(T::Boolean) }
  def expired?
    ended? || Time.current > T.must(began_at) + 24.hours
  end

  # Returns true if this is a studio representation session (no trustee_grant)
  sig { returns(T::Boolean) }
  def studio_representation?
    trustee_grant_id.nil?
  end

  # Returns true if this is a user representation session (has trustee_grant)
  sig { returns(T::Boolean) }
  def user_representation?
    trustee_grant_id.present?
  end

  # Returns the user being represented (for user representation) or nil (for studio)
  sig { returns(T.nilable(User)) }
  def represented_user
    return nil unless user_representation?

    trustee_grant&.granting_user
  end

  # Returns the user identity to use as current_user during this session.
  # For user representation: returns the granting_user (the person being represented)
  # For studio representation: returns the studio's trustee_user
  sig { returns(User) }
  def effective_user
    if user_representation?
      T.must(T.must(trustee_grant).granting_user)
    else
      T.must(T.must(superagent).trustee_user)
    end
  end

  # Returns a display name for what's being represented
  sig { returns(String) }
  def representation_label
    if user_representation?
      represented_user&.display_name || "User"
    else
      superagent&.name || "Studio"
    end
  end

  # Event-based recording methods
  sig do
    params(
      request: T.untyped,
      action_name: String,
      resource: T.untyped,
      context_resource: T.untyped
    ).returns(RepresentationSessionEvent)
  end
  def record_event!(request:, action_name:, resource:, context_resource: nil)
    raise "Session has ended" if ended?
    raise "Session has expired" if expired?

    RepresentationSessionEvent.create!(
      representation_session: self,
      tenant_id: tenant_id,
      superagent_id: superagent_id,
      action_name: action_name,
      resource: resource,
      context_resource: context_resource,
      resource_superagent_id: resource.superagent_id,
      request_id: request.request_id
    )
  end

  # For bulk actions - record one event per resource
  sig do
    params(
      request: T.untyped,
      action_name: String,
      resources: T::Array[T.untyped],
      context_resource: T.untyped
    ).void
  end
  def record_events!(request:, action_name:, resources:, context_resource: nil)
    raise "Session has ended" if ended?
    raise "Session has expired" if expired?

    resources.each do |resource|
      record_event!(
        request: request,
        action_name: action_name,
        resource: resource,
        context_resource: context_resource
      )
    end
  end

  sig { returns(String) }
  def title
    "Representation Session #{truncated_id}"
  end

  sig { returns(String) }
  def path
    if superagent
      # Studio representation session - path is studio-relative
      "/studios/#{T.must(superagent).handle}/r/#{truncated_id}"
    else
      # User representation session - path is via trustee grant
      grant = trustee_grant
      raise "Invalid state: RepresentationSession #{id} has no superagent and no trustee_grant" unless grant

      "/u/#{T.must(grant.granting_user).handle}/settings/trustee-grants/#{grant.truncated_id}"

    end
  end

  sig { returns(String) }
  def url
    "#{T.must(tenant).url}#{path}"
  end

  sig { returns(Integer) }
  def action_count
    representation_session_events.select(:request_id).distinct.count
  end

  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def activity_log_entries
    human_readable_events_log
  end

  # Activity log from events table - groups by request_id
  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def human_readable_events_log
    @human_readable_events_log ||= T.let(
      representation_session_events
        .includes(:resource, :context_resource)
        .order(created_at: :asc)
        .group_by(&:request_id)
        .map do |_request_id, events|
          # Take first event as representative (all share same action/context)
          event = T.must(events.first)
          display_resource = event.context_resource || event.resource
          {
            happened_at: event.created_at,
            verb_phrase: event.verb_phrase,
            superagent: display_resource.respond_to?(:superagent) ? display_resource.superagent : nil,
            main_resource: display_resource,
            event_count: events.size, # e.g., "voted on Decision (3 votes)"
          }
        end,
      T.nilable(T::Array[T::Hash[Symbol, T.untyped]])
    )
  end

  # Override reload to clear memoized instance variables
  sig { params(options: T.untyped).returns(T.self_type) }
  def reload(options = nil)
    @human_readable_events_log = nil
    super
  end
end
