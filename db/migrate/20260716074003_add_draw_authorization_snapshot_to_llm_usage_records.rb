class AddDrawAuthorizationSnapshotToLLMUsageRecords < ActiveRecord::Migration[7.2]
  # A pool draw's receipt: the terms it was authorized against, snapshotted at
  # selection time so a later dispute can be settled from the ledger alone
  # rather than reconstructed through the mutable enrollment. All nullable —
  # NULL means either an individual-payer draw (no pool authorized it) or a row
  # opened before receipts existed. The historical ceiling was never recorded
  # and the enrollment is mutable, so there is nothing honest to backfill.
  #
  # funding_pool_enrollment_id is a soft pointer, deliberately not a foreign
  # key: the enrollment row is destroyed with its pool, but the receipt must
  # outlive both (the same point-in-time reasoning that keeps
  # payer_stripe_customer_id a bare string, not an FK).
  def change
    change_table :llm_usage_records, bulk: true do |t|
      t.uuid :funding_pool_enrollment_id
      t.integer :enrollment_draw_cap_cents
      t.string :enrollment_draw_cap_period
      t.integer :pool_member_draw_cap_cents
      t.string :pool_member_draw_cap_period
    end
  end
end
