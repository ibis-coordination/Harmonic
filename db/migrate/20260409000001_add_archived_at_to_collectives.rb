class AddArchivedAtToCollectives < ActiveRecord::Migration[7.2]
  def change
    add_column :collectives, :archived_at, :datetime
  end
end
