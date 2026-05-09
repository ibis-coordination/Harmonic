class AddImportOptionsToDataImports < ActiveRecord::Migration[7.2]
  def change
    add_column :data_imports, :import_options, :jsonb, default: {}, null: false
  end
end
