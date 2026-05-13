# typed: false

class AddTombstonedAtToNotes < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :tombstoned_at, :datetime
    add_index :notes, :tombstoned_at
  end
end
