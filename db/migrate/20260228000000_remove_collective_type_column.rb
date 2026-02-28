class RemoveCollectiveTypeColumn < ActiveRecord::Migration[7.2]
  def up
    remove_column :collectives, :collective_type
  end

  def down
    add_column :collectives, :collective_type, :string, null: true
  end
end
