class AddFinalStatementToDecisions < ActiveRecord::Migration[7.2]
  def change
    add_column :decisions, :final_statement, :text
  end
end
