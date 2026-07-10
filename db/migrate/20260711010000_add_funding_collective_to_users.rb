class AddFundingCollectiveToUsers < ActiveRecord::Migration[7.2]
  # An AI agent's token spend can be funded by an agent_funding collective
  # (its members' balances, drawn per call) instead of its own billing
  # customer. Deliberately NOT named collective_id: ApplicationRecord
  # auto-scopes any table carrying that column name, and users must stay
  # unscoped.
  def change
    add_column :users, :funding_collective_id, :uuid
    add_index :users, :funding_collective_id, where: "funding_collective_id IS NOT NULL"
    add_foreign_key :users, :collectives, column: :funding_collective_id
  end
end
