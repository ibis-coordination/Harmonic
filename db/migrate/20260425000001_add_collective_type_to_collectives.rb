class AddCollectiveTypeToCollectives < ActiveRecord::Migration[7.2]
  def change
    add_column :collectives, :collective_type, :string, default: "standard", null: false
    add_index :collectives, :collective_type
  end
end
