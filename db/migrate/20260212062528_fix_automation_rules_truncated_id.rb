# typed: true

class FixAutomationRulesTruncatedId < ActiveRecord::Migration[7.0]
  def up
    # Remove the existing truncated_id column
    remove_index :automation_rules, :truncated_id
    remove_column :automation_rules, :truncated_id

    # Add a generated column that auto-computes from id (matching webhooks table)
    execute <<-SQL
      ALTER TABLE automation_rules
      ADD COLUMN truncated_id character varying GENERATED ALWAYS AS (LEFT(id::text, 8)) STORED NOT NULL
    SQL

    add_index :automation_rules, :truncated_id, unique: true
  end

  def down
    remove_index :automation_rules, :truncated_id
    remove_column :automation_rules, :truncated_id

    add_column :automation_rules, :truncated_id, :string, limit: 8
    add_index :automation_rules, :truncated_id, unique: true
  end
end
