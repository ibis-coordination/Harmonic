class AddRuleRecurrenceToAiAgentTaskRuns < ActiveRecord::Migration[7.2]
  def change
    # How many earlier runs of the same automation rule appear in this run's
    # lineage chain. Like chain_depth: observability, not enforcement.
    add_column :ai_agent_task_runs, :rule_recurrence, :integer, default: 0, null: false
  end
end
