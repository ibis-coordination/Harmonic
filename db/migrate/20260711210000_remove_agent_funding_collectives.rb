class RemoveAgentFundingCollectives < ActiveRecord::Migration[7.2]
  # Funding pools (see CreateFundingPools) replace the agent_funding
  # collective type. This migration asserts the type is unused and drops its
  # columns. Prod and sandbox were verified to have zero agent_funding rows
  # before the remodel; dev smoke fixtures must be recreated as pools and the
  # old rows deleted before this runs (it raises rather than guessing at a
  # data conversion nobody needs).
  def up
    orphans = select_value("SELECT COUNT(*) FROM collectives WHERE collective_type = 'agent_funding'").to_i
    if orphans.positive?
      raise "#{orphans} agent_funding collective(s) still exist. Recreate them as funding pools " \
            "on standard collectives and delete the rows, then re-run this migration."
    end

    linked = select_value("SELECT COUNT(*) FROM users WHERE funding_collective_id IS NOT NULL").to_i
    if linked.positive?
      raise "#{linked} user(s) still link to a funding collective. Re-attach them to funding pools " \
            "(users.funding_pool_id) and clear funding_collective_id, then re-run this migration."
    end

    # Pre-remodel ledger rows can keep their payer attribution but lose the
    # pool link — they were smoke-test draws; funding_pool_id is the
    # successor column for real usage.
    execute("UPDATE llm_usage_records SET funding_collective_id = NULL WHERE funding_collective_id IS NOT NULL")

    remove_column :users, :funding_collective_id
    remove_column :llm_usage_records, :funding_collective_id
    # The per-member draw ceiling lives on funding_pools now.
    remove_column :collectives, :member_daily_draw_cap_cents
  end

  def down
    add_column :collectives, :member_daily_draw_cap_cents, :integer

    add_column :users, :funding_collective_id, :uuid
    add_index :users, :funding_collective_id, where: "funding_collective_id IS NOT NULL"
    add_foreign_key :users, :collectives, column: :funding_collective_id

    add_column :llm_usage_records, :funding_collective_id, :uuid
    add_index :llm_usage_records, [:funding_collective_id, :payer_stripe_customer_id, :completed_at],
              where: "funding_collective_id IS NOT NULL",
              name: "idx_llm_usage_on_pool_payer_completed"
    add_foreign_key :llm_usage_records, :collectives, column: :funding_collective_id
  end
end
