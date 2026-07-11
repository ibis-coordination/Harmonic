class CreateLLMUsageRecords < ActiveRecord::Migration[7.2]
  # Payer-keyed billing ledger: one row per billed LLM call, opened as
  # "pending" when select-payer picks the payer and completed with token
  # counts + estimated cost by record-usage after the response. Feeds the
  # balance gate, spend caps, and per-agent accounting.
  #
  # Deliberately carries origin_tenant_id, NOT tenant_id: ApplicationRecord
  # auto-scopes any table with a tenant_id column, and balance gating must sum
  # a payer's spend across every tenant they fund agents in. Same posture as
  # stripe_customers (billing data is user-level, inherently cross-tenant).
  def change
    create_table :llm_usage_records, id: :uuid do |t|
      t.uuid :origin_tenant_id, null: false
      t.uuid :ai_agent_id, null: false
      # The pool the draw came from, stamped at selection time (nil = the
      # agent's own billing customer paid). Point-in-time attribution — the
      # agent's funding_collective link is mutable, so joins through it would
      # rewrite history when agents move between pools.
      t.uuid :funding_collective_id
      t.string :payer_stripe_customer_id, null: false
      t.string :selection_id, null: false
      t.string :status, null: false, default: "pending"
      t.string :model
      t.integer :input_tokens
      t.integer :output_tokens
      # Fractional cents: a single small call costs well under one cent.
      t.decimal :estimated_cost_cents, precision: 14, scale: 6
      t.uuid :ai_agent_task_run_id
      t.uuid :api_token_id
      # occurred_at is when the payer was selected (the row opened);
      # completed_at is when the cost landed. Spend sums anchor on
      # completed_at — a cost belongs to the moment it became known, or a
      # call straddling a snapshot refresh or a UTC-day boundary would be
      # counted nowhere.
      t.datetime :occurred_at, null: false
      t.datetime :completed_at
      t.timestamps
    end
    add_index :llm_usage_records, :selection_id, unique: true
    # occurred_at indexes serve the pending-reservation scans; completed_at
    # indexes serve the spend sums.
    add_index :llm_usage_records, [:payer_stripe_customer_id, :occurred_at]
    add_index :llm_usage_records, [:ai_agent_id, :occurred_at]
    add_index :llm_usage_records, [:payer_stripe_customer_id, :completed_at]
    add_index :llm_usage_records, [:ai_agent_id, :completed_at]
    # Covers the per-member draw-ceiling sum: pool + payer + day window.
    add_index :llm_usage_records, [:funding_collective_id, :payer_stripe_customer_id, :completed_at],
              where: "funding_collective_id IS NOT NULL",
              name: "idx_llm_usage_on_pool_payer_completed"
    add_foreign_key :llm_usage_records, :tenants, column: :origin_tenant_id
    add_foreign_key :llm_usage_records, :collectives, column: :funding_collective_id
    add_foreign_key :llm_usage_records, :users, column: :ai_agent_id
    add_foreign_key :llm_usage_records, :ai_agent_task_runs, column: :ai_agent_task_run_id
    add_foreign_key :llm_usage_records, :api_tokens, column: :api_token_id
  end
end
