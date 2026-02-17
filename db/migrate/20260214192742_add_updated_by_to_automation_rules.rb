class AddUpdatedByToAutomationRules < ActiveRecord::Migration[7.0]
  def change
    add_reference :automation_rules, :updated_by, type: :uuid, foreign_key: { to_table: :users }, index: true
  end
end
