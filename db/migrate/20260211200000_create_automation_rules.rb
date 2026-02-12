# typed: true

class CreateAutomationRules < ActiveRecord::Migration[7.0]
  def change
    create_table :automation_rules, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :superagent, type: :uuid, null: true, foreign_key: true
      t.references :user, type: :uuid, null: true, foreign_key: true
      t.references :ai_agent, type: :uuid, null: true, foreign_key: { to_table: :users }
      t.references :created_by, type: :uuid, null: false, foreign_key: { to_table: :users }

      t.string :name, null: false
      t.text :description
      t.string :truncated_id, limit: 8

      t.string :trigger_type, null: false # 'event', 'schedule', 'webhook'
      t.jsonb :trigger_config, null: false, default: {}
      t.jsonb :conditions, null: false, default: []
      t.jsonb :actions, null: false, default: []
      t.text :yaml_source

      t.boolean :enabled, default: true, null: false
      t.integer :execution_count, default: 0, null: false
      t.datetime :last_executed_at
      t.string :webhook_secret
      t.string :webhook_path

      t.timestamps
    end

    add_index :automation_rules, [:ai_agent_id, :enabled], name: "index_automation_rules_on_ai_agent_and_enabled"
    add_index :automation_rules, [:tenant_id, :superagent_id, :enabled], name: "index_automation_rules_on_tenant_superagent_enabled"
    add_index :automation_rules, :truncated_id, unique: true
    add_index :automation_rules, :webhook_path, unique: true, where: "webhook_path IS NOT NULL"
  end
end
