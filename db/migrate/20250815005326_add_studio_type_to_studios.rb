class AddStudioTypeToStudios < ActiveRecord::Migration[7.0]
  def change
    add_column :studios, :studio_type, :string, null: false, default: 'studio'
  end
end
