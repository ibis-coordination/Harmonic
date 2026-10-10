# typed: true

class Commitment < ApplicationRecord
  extend T::Sig
  include Tracked
  include Linkable
  include Pinnable
  include Commentable
  include HasTruncatedId
  include Attachable
  include Searchable
  include TracksUserItemStatus
  include HasRepresentationSessionEvents
  include SoftDeletable
  include Statementable
  include Summarizable
  SUBTYPES = ["action", "calendar_event", "policy"].freeze
  MAX_TITLE_LENGTH = 1000
  MAX_DESCRIPTION_LENGTH = 1_000_000

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :collective
  before_validation :set_collective_id
  belongs_to :created_by, class_name: "User"
  belongs_to :updated_by, class_name: "User"
  has_many :participants, class_name: "CommitmentParticipant", dependent: :destroy
  validates :title, presence: true, length: { maximum: MAX_TITLE_LENGTH }
  validates :description, length: { maximum: MAX_DESCRIPTION_LENGTH }
  # Optional: critical mass is not relevant to every commitment (a task
  # someone just needs to do, an event happening regardless of RSVPs, a
  # policy in effect regardless of signatories). nil means "no critical
  # mass" — the commitment simply collects participants.
  validates :critical_mass, numericality: { greater_than: 0 }, allow_nil: true
  validates :deadline, presence: true
  validates :subtype, inclusion: { in: SUBTYPES }
  validates :starts_at, presence: true, if: :is_calendar_event?
  validates :ends_at, presence: true, if: :is_calendar_event?
  validate :ends_at_after_starts_at, if: :is_calendar_event?

  sig { returns(T::Boolean) }
  def is_action?
    subtype == "action"
  end

  sig { returns(T::Boolean) }
  def is_calendar_event?
    subtype == "calendar_event"
  end

  sig { returns(T::Boolean) }
  def is_policy?
    subtype == "policy"
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    response = {
      id: id,
      truncated_id: truncated_id,
      subtype: subtype,
      title: title,
      description: description,
      deadline: deadline,
      critical_mass: critical_mass,
      starts_at: starts_at ? T.must(starts_at).iso8601 : nil,
      ends_at: ends_at ? T.must(ends_at).iso8601 : nil,
      location: location,
      participant_count: participant_count,
      created_at: created_at,
      updated_at: updated_at,
      created_by_id: created_by_id,
      updated_by_id: updated_by_id,
    }
    response.merge!({ participants: participants.map(&:api_json) }) if include.include?("participants")
    response.merge!({ backlinks: backlinks.map(&:api_json) }) if include.include?("backlinks")
    response
  end

  sig { returns(String) }
  def path_prefix
    "c"
  end

  def content_snapshot
    { title: raw_title, description: raw_description }
  end

  # Accessor masking for soft-deleted records. See SoftDeletable comments.
  sig { returns(T.nilable(String)) }
  def raw_title
    attributes["title"]
  end

  sig { returns(T.nilable(String)) }
  def raw_description
    attributes["description"]
  end

  sig { returns(T.nilable(String)) }
  def title
    return "[deleted]" if deleted?

    super
  end

  sig { returns(T.nilable(String)) }
  def description
    return "[deleted]" if deleted?

    super
  end

  sig { returns(T::Boolean) }
  def upcoming?
    s = starts_at
    return false unless s

    s > Time.current
  end

  sig { returns(T::Boolean) }
  def in_progress?
    s = starts_at
    e = ends_at
    return false unless s && e

    now = Time.current
    s <= now && e > now
  end

  sig { returns(T::Boolean) }
  def past?
    e = ends_at
    return false unless e

    e <= Time.current
  end

  sig { returns(T.nilable(ActiveSupport::Duration)) }
  def duration
    s = starts_at
    e = ends_at
    return nil unless s && e

    (e - s).seconds
  end

  sig { returns(T::Boolean) }
  def all_day?
    s = starts_at
    e = ends_at
    return false unless s && e

    tz = collective&.timezone&.tzinfo&.name || "UTC"
    s_local = s.in_time_zone(tz)
    e_local = e.in_time_zone(tz)
    s_local == s_local.beginning_of_day && e_local == e_local.beginning_of_day && e_local > s_local
  end

  sig { returns(String) }
  def formatted_time_range
    s = starts_at
    e = ends_at
    return "" unless s && e

    tz = collective&.timezone&.tzinfo&.name || "UTC"
    s_local = s.in_time_zone(tz)
    e_local = e.in_time_zone(tz)
    if all_day?
      if (e_local - 1.day) == s_local
        s_local.strftime("%b %-d, %Y")
      else
        "#{s_local.strftime("%b %-d")} – #{(e_local - 1.day).strftime("%b %-d, %Y")}"
      end
    elsif s_local.to_date == e_local.to_date
      "#{s_local.strftime("%b %-d, %-l:%M %p")} – #{e_local.strftime("%-l:%M %p")}"
    else
      "#{s_local.strftime("%b %-d, %-l:%M %p")} – #{e_local.strftime("%b %-d, %-l:%M %p")}"
    end
  end

  sig { returns(String) }
  def event_status
    return "Happening now" if in_progress?
    return "Upcoming" if upcoming?
    return "Past" if past?

    ""
  end

  sig { returns(T::Boolean) }
  def has_critical_mass?
    !critical_mass.nil?
  end

  sig { returns(String) }
  def status_message
    unless has_critical_mass?
      return closed? ? "Closed." : "Open"
    end

    # critical mass achieved
    return "Critical mass achieved." if critical_mass_achieved?
    # critical mass not achieved
    return "Failed to reach critical mass." if closed?

    # critical mass not achieved yet
    "Pending"
  end

  sig { returns(ActiveRecord::Relation) }
  def committed_participants
    @committed_participants ||= participants.where.not(committed_at: nil)
  end

  sig { returns(Integer) }
  def participant_count
    committed_participants.count
  end

  sig { returns(String) }
  def metric_name
    return "signatories" if is_policy?
    return "attendees" if is_calendar_event?

    "participants"
  end

  sig { returns(Integer) }
  def metric_value
    participant_count
  end

  sig { returns(String) }
  def octicon_metric_icon_name
    "person"
  end

  sig { returns(Integer) }
  def remaining_needed_for_critical_mass
    cm = critical_mass
    return 0 unless cm

    [cm - participant_count, 0].max
  end

  sig { returns(T::Boolean) }
  def critical_mass_achieved?
    cm = critical_mass
    return false unless cm

    participant_count >= cm
  end

  sig { returns(T::Boolean) }
  def limit_reached?
    !!(limit && participant_count >= T.must(limit))
  end

  sig { returns(T::Boolean) }
  def close_at_critical_mass?
    # The nil-guard matters: with no critical mass and no limit, nil == nil
    # must not read as "closes at critical mass".
    !!(critical_mass && limit == critical_mass)
  end

  sig { returns(T::Boolean) }
  def requires_manual_close?
    result = super
    return false unless result

    !close_at_critical_mass?
  end

  sig { params(participant_or_user: T.nilable(T.any(CommitmentParticipant, User))).returns(T::Boolean) }
  def can_edit_settings?(participant_or_user)
    return false if participant_or_user.nil?

    if participant_or_user.is_a?(CommitmentParticipant)
      participant_or_user.user_id == created_by_id
    else
      participant_or_user.id == created_by_id
    end
  end

  sig { params(participant_or_user: T.nilable(T.any(CommitmentParticipant, User))).returns(T::Boolean) }
  def can_close?(participant_or_user)
    can_edit_settings?(participant_or_user)
  end

  sig { void }
  def close_if_limit_reached
    return if limit.nil?

    @committed_participants = nil # clear cached collection in case a new participant was just added
    return unless limit_reached? && !closed?

    self.deadline = T.cast(Time.current, ActiveSupport::TimeWithZone)
  end

  sig { void }
  def close_if_limit_reached!
    close_if_limit_reached
    save!
  end

  sig { returns(Integer) }
  def progress_percentage
    return 100 if critical_mass_achieved?
    return 0 unless has_critical_mass?

    [(participant_count.to_f / critical_mass.to_f * 100).round, 100].min
  end

  sig { params(user: User).returns(CommitmentParticipant) }
  def join_commitment!(user)
    participant = CommitmentParticipantManager.new(commitment: self, user: user).find_or_create_participant
    participant.committed = true
    participant.save!
    close_if_limit_reached!
    participant
  end

  private

  sig { void }
  def ends_at_after_starts_at
    s = starts_at
    e = ends_at
    return unless s && e
    return unless e <= s

    errors.add(:ends_at, "must be after starts_at")
  end

  # Track the creator of this commitment
  def user_item_status_updates
    return [] if created_by_id.blank?

    [
      {
        tenant_id: tenant_id,
        user_id: created_by_id,
        item_type: "Commitment",
        item_id: id,
        is_creator: true,
      },
    ]
  end
end
