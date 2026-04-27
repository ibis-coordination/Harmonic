class AddTableDataToNotes < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :table_data, :jsonb, null: true
  end
end
