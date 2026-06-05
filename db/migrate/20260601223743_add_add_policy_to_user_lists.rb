class AddAddPolicyToUserLists < ActiveRecord::Migration[7.2]
  def change
    add_column :user_lists, :add_policy, :string, null: false, default: "owner_only"
  end
end
