class CreateChatSessions < ActiveRecord::Migration[7.2]
  def change
    create_table :chat_sessions, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :collective, type: :uuid, null: false, foreign_key: true
      t.references :ai_agent, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :initiated_by, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :chat_sessions, [:ai_agent_id, :initiated_by_id, :status]
  end
end
