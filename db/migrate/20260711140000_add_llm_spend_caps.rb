class AddLLMSpendCaps < ActiveRecord::Migration[7.2]
  # Two spend ceilings enforced per call by LLMGateway::PayerResolver against
  # the usage ledger (nil = uncapped):
  # - users.llm_daily_spend_cap_cents: how much an AI agent may spend per UTC
  #   day, whoever pays.
  # - collectives.member_daily_draw_cap_cents: how much an agent_funding
  #   collective may draw from any single member per UTC day.
  def change
    add_column :users, :llm_daily_spend_cap_cents, :integer
    add_column :collectives, :member_daily_draw_cap_cents, :integer
  end
end
