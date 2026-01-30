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
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent
  before_validation :set_superagent_id
  belongs_to :created_by, class_name: 'User', foreign_key: 'created_by_id'
  belongs_to :updated_by, class_name: 'User', foreign_key: 'updated_by_id'
  has_many :participants, class_name: 'CommitmentParticipant', dependent: :destroy
  validates :title, presence: true
  validates :critical_mass, presence: true, numericality: { greater_than: 0 }
  validates :deadline, presence: true

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    response = {
      id: id,
      truncated_id: truncated_id,
      title: title,
      description: description,
      deadline: deadline,
      critical_mass: critical_mass,
      participant_count: participant_count,
      created_at: created_at,
      updated_at: updated_at,
      created_by_id: created_by_id,
      updated_by_id: updated_by_id,
    }
    if include.include?('participants')
      response.merge!({ participants: participants.map(&:api_json) })
    end
    if include.include?('backlinks')
      response.merge!({ backlinks: backlinks.map(&:api_json) })
    end
    response
  end

  sig { returns(String) }
  def path_prefix
    'c'
  end

  sig { returns(String) }
  def status_message
    # critical mass achieved
    return 'Critical mass achieved.' if critical_mass_achieved?
    # critical mass not achieved
    return 'Failed to reach critical mass.' if closed?
    # critical mass not achieved yet
    return "Pending"
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
    'participants'
  end

  sig { returns(Integer) }
  def metric_value
    participant_count
  end

  sig { returns(String) }
  def octicon_metric_icon_name
    'person'
  end

  sig { returns(Integer) }
  def remaining_needed_for_critical_mass
    [T.must(critical_mass) - participant_count, 0].max
  end

  sig { returns(T::Boolean) }
  def critical_mass_achieved?
    participant_count >= T.must(critical_mass)
  end

  sig { returns(T::Boolean) }
  def limit_reached?
    !!(limit && participant_count >= T.must(limit))
  end

  sig { returns(T::Boolean) }
  def close_at_critical_mass?
    limit == critical_mass
  end

  sig { returns(T::Boolean) }
  def requires_manual_close?
    result = super
    return false unless result
    !close_at_critical_mass?
  end

  sig { params(participant_or_user: T.any(CommitmentParticipant, User)).returns(T::Boolean) }
  def can_edit_settings?(participant_or_user)
    if participant_or_user.is_a?(CommitmentParticipant)
      participant_or_user.user_id == created_by_id
    else
      participant_or_user.id == created_by_id
    end
  end

  sig { params(participant_or_user: T.any(CommitmentParticipant, User)).returns(T::Boolean) }
  def can_close?(participant_or_user)
    can_edit_settings?(participant_or_user)
  end

  sig { void }
  def close_if_limit_reached
    return if limit.nil?
    @committed_participants = nil # clear cached collection in case a new participant was just added
    if limit_reached? && !closed?
      self.deadline = T.cast(Time.current, ActiveSupport::TimeWithZone)
    end
  end

  sig { void }
  def close_if_limit_reached!
    close_if_limit_reached
    save!
  end

  sig { returns(Integer) }
  def progress_percentage
    return 100 if critical_mass_achieved?
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