class AddModelToSubagentTaskRuns < ActiveRecord::Migration[7.0]
  def change
    add_column :subagent_task_runs, :model, :string
  end
end
