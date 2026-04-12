class AddBillingExemptToCollectives < ActiveRecord::Migration[7.2]
  def change
    add_column :collectives, :billing_exempt, :boolean, default: false, null: false
  end
end
