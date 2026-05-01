class MigrateFinalStatementToStatementNotes < ActiveRecord::Migration[7.2]
  def up
    # Migrate existing final_statement text to statement notes
    execute <<~SQL
      INSERT INTO notes (id, subtype, text, title, statementable_type, statementable_id,
                         created_by_id, updated_by_id, tenant_id, collective_id,
                         deadline, created_at, updated_at, edit_access)
      SELECT gen_random_uuid(), 'statement', final_statement, 'Final Statement',
             'Decision', id,
             created_by_id, created_by_id, tenant_id, collective_id,
             COALESCE(deadline, NOW()), NOW(), NOW(), 'owner'
      FROM decisions
      WHERE final_statement IS NOT NULL AND final_statement != ''
    SQL

    remove_column :decisions, :final_statement
  end

  def down
    add_column :decisions, :final_statement, :text

    # Migrate statement notes back to final_statement column
    execute <<~SQL
      UPDATE decisions
      SET final_statement = notes.text
      FROM notes
      WHERE notes.statementable_type = 'Decision'
        AND notes.statementable_id = decisions.id
        AND notes.subtype = 'statement'
    SQL
  end
end
