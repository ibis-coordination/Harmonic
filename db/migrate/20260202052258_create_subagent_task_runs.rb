class CreateSubagentTaskRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :subagent_task_runs, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :subagent, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.references :initiated_by, null: false, foreign_key: { to_table: :users }, type: :uuid

      t.text :task, null: false
      t.integer :max_steps, null: false, default: 15
      t.string :status, null: false, default: "pending"
      t.boolean :success
      t.text :final_message
      t.text :error
      t.integer :steps_count, default: 0
      t.jsonb :steps_data, default: []

      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :subagent_task_runs, [:tenant_id, :subagent_id]
    add_index :subagent_task_runs, [:tenant_id, :initiated_by_id]
    add_index :subagent_task_runs, :status
  end
end
