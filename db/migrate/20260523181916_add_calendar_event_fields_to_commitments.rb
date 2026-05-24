# typed: false

class AddCalendarEventFieldsToCommitments < ActiveRecord::Migration[7.2]
  def change
    add_column :commitments, :starts_at, :timestamp, null: true
    add_column :commitments, :ends_at, :timestamp, null: true
    add_column :commitments, :location, :text, null: true

    add_index :commitments, [:tenant_id, :collective_id, :starts_at],
              where: "starts_at IS NOT NULL",
              name: "index_commitments_on_starts_at"
  end
end
