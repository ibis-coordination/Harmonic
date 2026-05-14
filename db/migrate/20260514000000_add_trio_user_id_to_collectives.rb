class AddTrioUserIdToCollectives < ActiveRecord::Migration[7.2]
  def change
    add_column :collectives, :trio_user_id, :uuid
  end
end
