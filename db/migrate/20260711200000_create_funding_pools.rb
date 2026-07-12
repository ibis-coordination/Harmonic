class CreateFundingPools < ActiveRecord::Migration[7.2]
  # A funding pool is a standard collective's pooled-LLM-funding instrument:
  # enrolled members' prepaid balances fund the collective's attached agents,
  # one payer drawn uniformly at random per call (LLMGateway::PayerResolver).
  # Social membership in the collective stays free — the billing consent
  # lives on the enrollment, not the membership. This replaces the standalone
  # agent_funding collective type; a follow-up migration removes it.
  def change
    create_table :funding_pools, id: :uuid do |t|
      t.uuid :tenant_id, null: false
      t.uuid :collective_id, null: false
      t.uuid :created_by_id, null: false
      # Per-UTC-day ceiling on drawing from any one enrolled member (nil =
      # uncapped), enforced per call in LLMGateway::PayerResolver.
      t.integer :member_daily_draw_cap_cents
      t.datetime :archived_at
      t.timestamps
    end
    add_index :funding_pools, :collective_id, unique: true
    add_foreign_key :funding_pools, :tenants
    add_foreign_key :funding_pools, :collectives
    add_foreign_key :funding_pools, :users, column: :created_by_id

    create_table :funding_pool_enrollments, id: :uuid do |t|
      t.uuid :tenant_id, null: false
      # Denormalized from the pool (model-validated to match) so the table is
      # explicitly collective-scoped like every other collective-bound table.
      t.uuid :collective_id, null: false
      t.uuid :funding_pool_id, null: false
      t.uuid :user_id, null: false
      # Withdrawal archives rather than deletes: the row is the consent
      # record for draws already made against this member's balance.
      t.datetime :archived_at
      t.timestamps
    end
    add_index :funding_pool_enrollments, [:funding_pool_id, :user_id], unique: true
    add_index :funding_pool_enrollments, :user_id
    add_index :funding_pool_enrollments, :collective_id
    add_foreign_key :funding_pool_enrollments, :tenants
    add_foreign_key :funding_pool_enrollments, :collectives
    add_foreign_key :funding_pool_enrollments, :funding_pools
    add_foreign_key :funding_pool_enrollments, :users

    # Successor to users.funding_collective_id (dropped in the follow-up
    # migration once the resolver reads pools).
    add_column :users, :funding_pool_id, :uuid
    add_index :users, :funding_pool_id, where: "funding_pool_id IS NOT NULL"
    add_foreign_key :users, :funding_pools

    # Successor to llm_usage_records.funding_collective_id: the pool a draw
    # came from, stamped at selection time for point-in-time attribution.
    add_column :llm_usage_records, :funding_pool_id, :uuid
    add_index :llm_usage_records, [:funding_pool_id, :payer_stripe_customer_id, :completed_at],
              where: "funding_pool_id IS NOT NULL",
              name: "idx_llm_usage_on_funding_pool_payer_completed"
    add_foreign_key :llm_usage_records, :funding_pools
  end
end
