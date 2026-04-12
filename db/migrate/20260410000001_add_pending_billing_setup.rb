class AddPendingBillingSetup < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :pending_billing_setup, :boolean, default: false, null: false
    add_column :collectives, :pending_billing_setup, :boolean, default: false, null: false
  end
end
