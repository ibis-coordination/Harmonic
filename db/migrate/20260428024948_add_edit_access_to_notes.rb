class AddEditAccessToNotes < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :edit_access, :string, null: false, default: "owner"
  end
end
