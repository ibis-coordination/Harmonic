class CreateAutomationRuleRunResources < ActiveRecord::Migration[7.0]
  def change
    create_table :automation_rule_run_resources, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :automation_rule_run, null: false, foreign_key: true, type: :uuid
      t.string :resource_type, null: false
      t.uuid :resource_id, null: false
      t.references :resource_superagent, null: false, foreign_key: { to_table: :superagents }, type: :uuid
      t.string :action_type
      t.string :display_path

      t.timestamps
    end

    add_index :automation_rule_run_resources, [:resource_type, :resource_id], name: "index_automation_run_resources_on_resource"
    add_index :automation_rule_run_resources, [:tenant_id, :resource_type, :resource_id], name: "index_automation_run_resources_on_tenant_and_resource"
  end
end
