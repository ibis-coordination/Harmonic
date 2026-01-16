class AddSuspensionToTenants < ActiveRecord::Migration[7.0]
  def change
    add_column :tenants, :suspended_at, :datetime
    add_column :tenants, :suspended_reason, :string
  end
end
