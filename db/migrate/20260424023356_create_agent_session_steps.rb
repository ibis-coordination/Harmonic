class CreateAgentSessionSteps < ActiveRecord::Migration[7.2]
  def change
    create_table :agent_session_steps, id: :uuid do |t|
      t.references :ai_agent_task_run, type: :uuid, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :step_type, null: false
      t.references :sender, type: :uuid, null: true, foreign_key: { to_table: :users }
      t.jsonb :detail, null: false, default: {}

      t.timestamp :created_at, null: false
    end

    add_index :agent_session_steps, [:ai_agent_task_run_id, :position], unique: true
  end
end
