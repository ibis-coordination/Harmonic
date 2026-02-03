class CreateSubagentTaskRunResources < ActiveRecord::Migration[7.0]
  def change
    create_table :subagent_task_run_resources, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :subagent_task_run, null: false, foreign_key: true, type: :uuid,
                   index: { name: "idx_task_run_resources_on_task_run_id" }
      t.references :resource, null: false, polymorphic: true, type: :uuid,
                   index: { name: "idx_task_run_resources_on_resource" }
      # Track which superagent owns the resource (may differ from task run's starting superagent)
      t.references :resource_superagent, null: false, foreign_key: { to_table: :superagents }, type: :uuid,
                   index: { name: "idx_task_run_resources_on_resource_superagent" }
      t.string :action_type # 'create', 'update', 'vote', 'commit', etc.

      t.timestamps
    end

    add_index :subagent_task_run_resources,
              [:subagent_task_run_id, :resource_id, :resource_type],
              unique: true,
              name: "idx_task_run_resources_unique"
  end
end
