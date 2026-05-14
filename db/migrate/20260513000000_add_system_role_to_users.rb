class AddSystemRoleToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :system_role, :string
    add_index :users, :system_role, where: "system_role IS NOT NULL"
  end
end
