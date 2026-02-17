# typed: true

class AddSuperagentToAutomationRuleRuns < ActiveRecord::Migration[7.0]
  def change
    add_reference :automation_rule_runs, :superagent, type: :uuid, null: true, foreign_key: true

    add_index :automation_rule_runs, [:superagent_id, :created_at], name: "index_automation_rule_runs_on_superagent_and_created"
  end
end
