class AddAdminFlagsToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :app_admin, :boolean, default: false, null: false
    add_column :users, :sys_admin, :boolean, default: false, null: false
  end
end
