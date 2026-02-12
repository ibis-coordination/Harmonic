class AddTokenUsageToAiAgentTaskRuns < ActiveRecord::Migration[7.0]
  def change
    add_column :ai_agent_task_runs, :input_tokens, :integer, default: 0
    add_column :ai_agent_task_runs, :output_tokens, :integer, default: 0
    add_column :ai_agent_task_runs, :total_tokens, :integer, default: 0
    add_column :ai_agent_task_runs, :estimated_cost_usd, :decimal, precision: 10, scale: 6

    add_index :ai_agent_task_runs, [:tenant_id, :created_at]
    add_index :ai_agent_task_runs, [:ai_agent_id, :created_at]
  end
end
