class AddDescriptionToStudios < ActiveRecord::Migration[7.0]
  def change
    add_column :studios, :description, :text
  end
end
