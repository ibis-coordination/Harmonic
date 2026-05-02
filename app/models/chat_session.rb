# typed: true

class ChatSession < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :ai_agent, class_name: "User"
  belongs_to :initiated_by, class_name: "User"

  has_many :task_runs, class_name: "AiAgentTaskRun", dependent: :nullify
  has_many :chat_messages, dependent: :destroy

  validates :ai_agent_id, uniqueness: { scope: [:tenant_id, :initiated_by_id] }

  sig { params(agent: User, user: User, tenant: Tenant).returns(ChatSession) }
  def self.find_or_create_for(agent:, user:, tenant:)
    find_or_create_by!(
      tenant: tenant,
      ai_agent: agent,
      initiated_by: user
    )
  rescue ActiveRecord::RecordNotUnique
    find_by!(
      tenant: tenant,
      ai_agent: agent,
      initiated_by: user
    )
  end

  sig { returns(T.untyped) }
  def messages
    chat_messages.order(:created_at)
  end
end
