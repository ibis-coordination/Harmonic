class AddArchivedAtToTenants < ActiveRecord::Migration[7.0]
  def change
    add_column :tenants, :archived_at, :datetime
  end
end
