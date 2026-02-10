# typed: true

class AiAgentTaskRunResource < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :ai_agent_task_run
  belongs_to :resource, polymorphic: true
  belongs_to :resource_superagent, class_name: "Superagent"

  validates :resource_type, inclusion: {
    in: ["Note", "Decision", "Commitment", "Option", "Vote", "CommitmentParticipant", "NoteHistoryEvent"],
  }
  validates :action_type, inclusion: {
    in: ["create", "update", "confirm", "add_options", "vote", "commit"],
  }
  validate :resource_superagent_matches_resource

  # Override default scope - this model is NOT scoped by superagent_id since it tracks
  # resources that may belong to different superagents than where the task run started
  def self.default_scope
    where(tenant_id: Tenant.current_id)
  end

  # Find the task run that created a given resource (if any)
  # Returns nil if the resource was not created by an AI agent task run
  sig { params(resource: T.untyped).returns(T.nilable(AiAgentTaskRun)) }
  def self.task_run_for(resource)
    return nil unless resource.respond_to?(:id) && resource.respond_to?(:class)

    record = find_by(
      resource_type: resource.class.name,
      resource_id: resource.id,
      action_type: "create"
    )
    record&.ai_agent_task_run
  end

  # Load the resource bypassing default scope (needed because resources may be in different superagents)
  sig { returns(T.untyped) }
  def resource_unscoped
    return nil if resource_type.blank? || resource_id.blank?

    resource_type.constantize.tenant_scoped_only(tenant_id).find_by(id: resource_id)
  end

  # Generate a human-readable title for display in the UI
  # Takes the resource as a parameter to avoid re-fetching it
  # Uses unscoped queries for related resources to handle cross-superagent associations
  sig { params(resource: T.untyped).returns(String) }
  def display_title(resource)
    return "Unknown resource" if resource.nil?

    case resource
    when Note
      resource.title.to_s.truncate(60)
    when Decision
      resource.title.to_s.truncate(60)
    when Commitment
      resource.title.to_s.truncate(60)
    when Option
      "Option: #{resource.title.to_s.truncate(50)}"
    when Vote
      option = Option.tenant_scoped_only(tenant_id).find_by(id: resource.option_id)
      option_title = option&.title || "unknown option"
      "Vote on: #{option_title.truncate(50)}"
    when NoteHistoryEvent
      note = Note.tenant_scoped_only(tenant_id).find_by(id: resource.note_id)
      note_title = note&.title || "unknown note"
      "Confirmed: #{note_title.truncate(50)}"
    when CommitmentParticipant
      commitment = Commitment.tenant_scoped_only(tenant_id).find_by(id: resource.commitment_id)
      commitment_title = commitment&.title || "unknown commitment"
      "Joined: #{commitment_title.truncate(50)}"
    else
      "#{resource.class.name} #{resource.id.to_s[0..7]}"
    end
  end

  sig { void }
  def set_tenant_id
    return if tenant_id.present?

    self.tenant_id = T.must(ai_agent_task_run&.tenant_id || Tenant.current_id)
  end

  sig { void }
  def resource_superagent_matches_resource
    return if resource.blank?
    return unless resource.respond_to?(:superagent_id)
    return if resource_superagent_id == T.unsafe(resource).superagent_id

    errors.add(:resource_superagent, "must match resource's superagent")
  end
end
