class AddBillingExemptToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :billing_exempt, :boolean, default: false, null: false
  end
end
