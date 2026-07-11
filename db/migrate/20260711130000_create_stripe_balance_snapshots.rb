class CreateStripeBalanceSnapshots < ActiveRecord::Migration[7.2]
  # Cached Stripe credit-balance reads for the per-call balance gate: the
  # gate computes snapshot minus ledger-spend-since-snapshot instead of
  # calling Stripe per call. One row per Stripe customer, refreshed on TTL
  # expiry / zero-crossing / top-up. No tenant column: billing data is
  # customer-keyed and inherently cross-tenant, like stripe_customers.
  def change
    create_table :stripe_balance_snapshots, id: :uuid do |t|
      t.string :stripe_customer_id, null: false
      t.integer :balance_cents, null: false
      t.datetime :fetched_at, null: false
      t.timestamps
    end
    add_index :stripe_balance_snapshots, :stripe_customer_id, unique: true
  end
end
