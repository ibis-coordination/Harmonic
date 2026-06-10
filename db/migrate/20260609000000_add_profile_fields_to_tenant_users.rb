# typed: true

class AddProfileFieldsToTenantUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :tenant_users, :bio,      :text
    add_column :tenant_users, :location, :string
    add_column :tenant_users, :website,  :string
  end
end
