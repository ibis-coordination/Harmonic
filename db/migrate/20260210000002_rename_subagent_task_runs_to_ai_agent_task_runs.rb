class RenameSubagentTaskRunsToAiAgentTaskRuns < ActiveRecord::Migration[7.0]
  def up
    # Rename tables
    rename_table :subagent_task_runs, :ai_agent_task_runs
    rename_table :subagent_task_run_resources, :ai_agent_task_run_resources

    # Rename foreign key columns
    rename_column :ai_agent_task_runs, :subagent_id, :ai_agent_id
    rename_column :ai_agent_task_run_resources, :subagent_task_run_id, :ai_agent_task_run_id
  end

  def down
    rename_column :ai_agent_task_run_resources, :ai_agent_task_run_id, :subagent_task_run_id
    rename_column :ai_agent_task_runs, :ai_agent_id, :subagent_id
    rename_table :ai_agent_task_run_resources, :subagent_task_run_resources
    rename_table :ai_agent_task_runs, :subagent_task_runs
  end
end
