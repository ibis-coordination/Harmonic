class AddDecisionMakerAndRenameLogToExecutive < ActiveRecord::Migration[7.2]
  def up
    add_column :decisions, :decision_maker_id, :uuid, null: true
    add_foreign_key :decisions, :users, column: :decision_maker_id

    # Rename 'log' subtype to 'executive'
    execute "UPDATE decisions SET subtype = 'executive' WHERE subtype = 'log'"
    # Also update search index if table exists
    if table_exists?(:search_indices)
      execute "UPDATE search_indices SET subtype = 'executive' WHERE item_type = 'Decision' AND subtype = 'log'"
    end
  end

  def down
    execute "UPDATE decisions SET subtype = 'log' WHERE subtype = 'executive'"
    if table_exists?(:search_indices)
      execute "UPDATE search_indices SET subtype = 'log' WHERE item_type = 'Decision' AND subtype = 'executive'"
    end

    remove_foreign_key :decisions, column: :decision_maker_id
    remove_column :decisions, :decision_maker_id
  end
end
