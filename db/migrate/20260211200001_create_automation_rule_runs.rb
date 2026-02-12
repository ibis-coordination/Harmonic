# typed: true

class CreateAutomationRuleRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :automation_rule_runs, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :automation_rule, type: :uuid, null: false, foreign_key: true
      t.references :triggered_by_event, type: :uuid, null: true, foreign_key: { to_table: :events }
      t.references :ai_agent_task_run, type: :uuid, null: true, foreign_key: true

      t.string :trigger_source # 'event', 'schedule', 'webhook', 'manual'
      t.jsonb :trigger_data, default: {}
      t.string :status, default: "pending" # pending, running, completed, failed, skipped
      t.jsonb :actions_executed, default: []
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :automation_rule_runs, [:automation_rule_id, :status], name: "index_automation_rule_runs_on_rule_and_status"
    add_index :automation_rule_runs, [:tenant_id, :created_at], name: "index_automation_rule_runs_on_tenant_and_created"
  end
end
