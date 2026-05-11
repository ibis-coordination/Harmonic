# typed: true

class AddExportTypeToDataExports < ActiveRecord::Migration[7.2]
  def change
    add_column :data_exports, :export_type, :string, null: false, default: "collective"
    add_index :data_exports, :export_type
  end
end
