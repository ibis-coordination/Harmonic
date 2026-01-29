class AddSuspensionToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :suspended_at, :datetime
    add_column :users, :suspended_by_id, :uuid
    add_column :users, :suspended_reason, :string
    add_index :users, :suspended_at
  end
end
