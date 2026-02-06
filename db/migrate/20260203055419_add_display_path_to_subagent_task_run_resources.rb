class AddDisplayPathToSubagentTaskRunResources < ActiveRecord::Migration[7.0]
  def change
    add_column :subagent_task_run_resources, :display_path, :string
  end
end
