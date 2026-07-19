# Task-run lineage: when the content that triggered an automation was itself
# created by a task run, that run is the new run's parent, and chain_depth
# counts the automated causation steps since the last human action
# (human-authored content has no creating run, so human participation resets
# the chain). Observability only — nothing dispatches or throttles on these.
class AddLineageToAiAgentTaskRuns < ActiveRecord::Migration[7.2]
  def change
    add_column :ai_agent_task_runs, :parent_task_run_id, :uuid
    add_column :ai_agent_task_runs, :chain_depth, :integer, default: 0, null: false
    add_index :ai_agent_task_runs, :parent_task_run_id
    add_foreign_key :ai_agent_task_runs, :ai_agent_task_runs, column: :parent_task_run_id
  end
end
