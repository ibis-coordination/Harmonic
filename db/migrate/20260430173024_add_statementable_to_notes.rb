class AddStatementableToNotes < ActiveRecord::Migration[7.2]
  def change
    add_column :notes, :statementable_type, :string
    add_column :notes, :statementable_id, :uuid
    add_index :notes, [:statementable_type, :statementable_id], unique: true
  end
end
