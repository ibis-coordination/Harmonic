class CreateUserBlocks < ActiveRecord::Migration[7.2]
  def change
    create_table :user_blocks, id: :uuid do |t|
      t.references :blocker, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :blocked, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.text :reason

      t.timestamps
    end

    add_index :user_blocks, [:blocker_id, :blocked_id, :tenant_id], unique: true
    add_index :user_blocks, [:blocked_id, :tenant_id]
  end
end
