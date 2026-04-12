class CreateStripeCustomers < ActiveRecord::Migration[7.2]
  def change
    create_table :stripe_customers, id: :uuid do |t|
      t.string :billable_type, null: false
      t.uuid :billable_id, null: false
      t.string :stripe_id, null: false
      t.string :stripe_subscription_id
      t.boolean :active, default: false, null: false

      t.timestamps
    end

    add_index :stripe_customers, [:billable_type, :billable_id], unique: true
    add_index :stripe_customers, :stripe_id, unique: true

    add_reference :users, :stripe_customer, type: :uuid, foreign_key: true, null: true
    add_reference :ai_agent_task_runs, :stripe_customer, type: :uuid, foreign_key: true, null: true
  end
end
