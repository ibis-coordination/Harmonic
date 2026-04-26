class RemoveStepsDataFromAiAgentTaskRuns < ActiveRecord::Migration[7.2]
  def change
    remove_column :ai_agent_task_runs, :steps_data, :jsonb, default: []
  end
end
