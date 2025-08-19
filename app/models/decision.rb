class Decision < ApplicationRecord
  include Tracked
  include Linkable
  include Pinnable
  include HasTruncatedId
  include Attachable
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :studio
  before_validation :set_studio_id
  belongs_to :created_by, class_name: 'User', foreign_key: 'created_by_id'
  belongs_to :updated_by, class_name: 'User', foreign_key: 'updated_by_id'
  has_many :decision_participants, dependent: :destroy
  has_many :options, dependent: :destroy
  has_many :approvals # dependent: :destroy through options

  validates :question, presence: true
  validates :deadline, presence: true

  def self.api_json
    map { |decision| decision.api_json }
  end

  def api_json(include: [])
    response = {
      id: id,
      truncated_id: truncated_id,
      question: question,
      description: description,
      options_open: options_open,
      deadline: deadline,
      created_at: created_at,
      updated_at: updated_at,
      voter_count: voter_count,
      # participants: decision_participants.map(&:api_json),
      # options: options.map(&:api_json),
      # approvals: approvals.map(&:api_json),
      # results: results.map(&:api_json),
      # history_events: history_events.map(&:api_json),
      # backlinks: backlinks.map(&:api_json),
    }
    if include.include?('participants')
      response.merge!({ participants: participants.map(&:api_json) })
    end
    if include.include?('options')
      response.merge!({ options: options.map(&:api_json) })
    end
    if include.include?('approvals')
      response.merge!({ approvals: approvals.map(&:api_json) })
    end
    if include.include?('results')
      response.merge!({ results: results.map(&:api_json) })
    end
    if include.include?('backlinks')
      response.merge!({ backlinks: backlinks.map(&:api_json) })
    end
    response
  end

  def title
    question
  end

  def participants
    decision_participants
  end

  def can_add_options?(participant)
    return false if closed? || !participant.authenticated?
    return true if options_open? || participant.user_id == created_by_id
    return false
  end

  def can_update_options?(participant)
    can_add_options?(participant)
  end

  def can_delete_options?(participant)
    can_add_options?(participant)
  end

  def can_edit_settings?(participant_or_user)
    if participant_or_user.is_a?(DecisionParticipant)
      participant_or_user.user_id == created_by_id
    else
      participant_or_user.id == created_by_id
    end
  end

  def can_close?(participant_or_user)
    can_edit_settings?(participant_or_user)
  end

  def close_at_critical_mass?
    false # This method is only required for parity with Commitment
  end

  def public?
    false
  end

  def results
    return @results if @results
    @results = DecisionResult.where(
      tenant_id: tenant_id,
      decision_id: self.id
    ).map.with_index do |result, index|
      result.position = index + 1
      result
    end
  end

  def view_count
    participants.count
  end

  def option_contributor_count
    options.distinct.count(:decision_participant_id)
  end

  def voter_count
    approvals.distinct.count(:decision_participant_id)
  end

  def voters
    return @voters if defined?(@voters)
    # TODO - clean this up
    @voters = DecisionParticipant.where(
      id: approvals.distinct.pluck(:decision_participant_id)
    ).includes(:user).map do |dp|
      dp.user
    end
  end

  def metric_name
    'voters'
  end

  def metric_value
    voter_count
  end

  def octicon_metric_icon_name
    'check-circle'
  end

  def path_prefix
    'd'
  end

end
