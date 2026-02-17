# typed: true
# frozen_string_literal: true

class AddChainMetadataToAutomationRuleRuns < ActiveRecord::Migration[7.0]
  def change
    add_column :automation_rule_runs, :chain_metadata, :jsonb, default: {}, null: false
  end
end
