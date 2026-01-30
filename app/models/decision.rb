# typed: true

class Decision < ApplicationRecord
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
  has_many :decision_participants, dependent: :destroy
  has_many :options, dependent: :destroy
  has_many :votes # dependent: :destroy through options

  validates :question, presence: true
  validates :deadline, presence: true

  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.api_json
    T.unsafe(self).map { |decision| decision.api_json }
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
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
      # votes: votes.map(&:api_json),
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
    if include.include?('votes')
      response.merge!({ votes: votes.map(&:api_json) })
    end
    if include.include?('results')
      response.merge!({ results: results.map(&:api_json) })
    end
    if include.include?('backlinks')
      response.merge!({ backlinks: backlinks.map(&:api_json) })
    end
    response
  end

  sig { returns(T.nilable(String)) }
  def title
    question
  end

  sig { returns(ActiveRecord::Relation) }
  def participants
    decision_participants
  end

  sig { params(participant: DecisionParticipant).returns(T::Boolean) }
  def can_add_options?(participant)
    return false if closed? || !participant.authenticated?
    return true if options_open? || participant.user_id == created_by_id
    return false
  end

  sig { params(participant: DecisionParticipant).returns(T::Boolean) }
  def can_update_options?(participant)
    can_add_options?(participant)
  end

  sig { params(participant: DecisionParticipant).returns(T::Boolean) }
  def can_delete_options?(participant)
    can_add_options?(participant)
  end

  sig { params(participant_or_user: T.any(DecisionParticipant, User)).returns(T::Boolean) }
  def can_edit_settings?(participant_or_user)
    if participant_or_user.is_a?(DecisionParticipant)
      participant_or_user.user_id == created_by_id
    else
      participant_or_user.id == created_by_id
    end
  end

  sig { params(participant_or_user: T.any(DecisionParticipant, User)).returns(T::Boolean) }
  def can_close?(participant_or_user)
    can_edit_settings?(participant_or_user)
  end

  sig { returns(T::Boolean) }
  def close_at_critical_mass?
    false # This method is only required for parity with Commitment
  end

  sig { returns(T::Boolean) }
  def public?
    false
  end

  sig { returns(T::Array[DecisionResult]) }
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

  sig { returns(Integer) }
  def view_count
    participants.count
  end

  sig { returns(Integer) }
  def option_contributor_count
    options.distinct.count(:decision_participant_id)
  end

  sig { returns(Integer) }
  def voter_count
    votes.distinct.count(:decision_participant_id)
  end

  sig { returns(T::Array[User]) }
  def voters
    return @voters if defined?(@voters)
    # TODO - clean this up
    @voters = DecisionParticipant.where(
      id: votes.distinct.pluck(:decision_participant_id)
    ).includes(:user).map do |dp|
      dp.user
    end.compact
  end

  sig { returns(String) }
  def metric_name
    'voters'
  end

  sig { returns(Integer) }
  def metric_value
    voter_count
  end

  sig { returns(String) }
  def octicon_metric_icon_name
    'check-circle'
  end

  sig { returns(String) }
  def path_prefix
    'd'
  end

  private

  # Track the creator of this decision
  def user_item_status_updates
    return [] if created_by_id.blank?

    [
      {
        tenant_id: tenant_id,
        user_id: created_by_id,
        item_type: "Decision",
        item_id: id,
        is_creator: true,
      },
    ]
  end
end
