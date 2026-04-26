class AddChatModeToAiAgentTaskRuns < ActiveRecord::Migration[7.2]
  def change
    add_column :ai_agent_task_runs, :mode, :string, null: false, default: "task"
    add_reference :ai_agent_task_runs, :chat_session, type: :uuid, null: true, foreign_key: true
  end
end
