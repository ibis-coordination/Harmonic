# typed: true
# frozen_string_literal: true

class AddAiAgentTaskRunIdToApiTokens < ActiveRecord::Migration[7.2]
  def change
    add_column :api_tokens, :ai_agent_task_run_id, :uuid, null: true
    add_index :api_tokens, :ai_agent_task_run_id
    add_foreign_key :api_tokens, :ai_agent_task_runs, column: :ai_agent_task_run_id
  end
end
