class AddSoftDeleteToContent < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :deleted_at, :datetime
    add_column :notes, :deleted_by_id, :uuid
    add_column :decisions, :deleted_at, :datetime
    add_column :decisions, :deleted_by_id, :uuid
    add_column :commitments, :deleted_at, :datetime
    add_column :commitments, :deleted_by_id, :uuid

    add_index :notes, :deleted_at
    add_index :decisions, :deleted_at
    add_index :commitments, :deleted_at
  end
end
