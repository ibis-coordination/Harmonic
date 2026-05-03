class CreateChatMessages < ActiveRecord::Migration[7.2]
  def change
    create_table :chat_messages, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :chat_session, type: :uuid, null: false, foreign_key: true
      t.references :sender, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.text :content, null: false

      t.timestamps
    end

    add_index :chat_messages, [:chat_session_id, :created_at]
  end
end
