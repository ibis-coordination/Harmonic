class UpdateUserTypeDefaultToHuman < ActiveRecord::Migration[7.0]
  def up
    change_column_default :users, :user_type, "human"
  end

  def down
    change_column_default :users, :user_type, "person"
  end
end
