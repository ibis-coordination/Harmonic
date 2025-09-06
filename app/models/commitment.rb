class Commitment < ApplicationRecord
  include Tracked
  include Linkable
  include Pinnable
  include Commentable
  include HasTruncatedId
  include Attachable
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :created_by, class_name: 'User', foreign_key: 'created_by_id'
  belongs_to :updated_by, class_name: 'User', foreign_key: 'updated_by_id'
  has_many :participants, class_name: 'CommitmentParticipant', dependent: :destroy
  validates :title, presence: true
  validates :critical_mass, presence: true, numericality: { greater_than: 0 }
  validates :deadline, presence: true

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

  def path_prefix
    'c'
  end

  def status_message
    # critical mass achieved
    return 'Critical mass achieved.' if critical_mass_achieved?
    # critical mass not achieved
    return 'Failed to reach critical mass.' if closed?
    # critical mass not achieved yet
    return "Pending"
  end

  def committed_participants
    @committed_participants ||= participants.where.not(committed_at: nil)
  end

  def participant_count
    committed_participants.count
  end

  def metric_name
    'participants'
  end

  def metric_value
    participant_count
  end

  def octicon_metric_icon_name
    'person'
  end

  def remaining_needed_for_critical_mass
    [critical_mass - participant_count, 0].max
  end

  def critical_mass_achieved?
    participant_count >= critical_mass
  end

  def limit_reached?
    limit && participant_count >= limit
  end

  def close_at_critical_mass?
    limit == critical_mass
  end

  def requires_manual_close?
    super && !close_at_critical_mass?
  end

  def can_edit_settings?(participant_or_user)
    if participant_or_user.is_a?(CommitmentParticipant)
      participant_or_user.user_id == created_by_id
    else
      participant_or_user.id == created_by_id
    end
  end

  def can_close?(participant_or_user)
    can_edit_settings?(participant_or_user)
  end

  def close_if_limit_reached
    return if limit.nil?
    @committed_participants = nil # clear cached collection in case a new participant was just added
    if limit_reached? && !closed?
      self.deadline = Time.current
    end
  end

  def close_if_limit_reached!
    close_if_limit_reached
    save!
  end

  def progress_percentage
    return 100 if critical_mass_achieved?
    [(participant_count.to_f / critical_mass.to_f * 100).round, 100].min
  end

  def join_commitment!(user)
    participant = CommitmentParticipantManager.new(commitment: self, user: user).find_or_create_participant
    participant.committed = true
    participant.save!
    close_if_limit_reached!
    participant
  end
end