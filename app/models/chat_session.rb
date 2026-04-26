# typed: true

class ChatSession < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :ai_agent, class_name: "User"
  belongs_to :initiated_by, class_name: "User"

  has_many :task_runs, class_name: "AiAgentTaskRun", dependent: :nullify

  sig { returns(T.untyped) }
  def messages
    AgentSessionStep.where(
      ai_agent_task_run_id: task_runs.select(:id),
      step_type: "message",
    ).order(:created_at)
  end
end
