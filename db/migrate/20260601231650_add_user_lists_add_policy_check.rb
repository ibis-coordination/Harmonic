class AddUserListsAddPolicyCheck < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      ALTER TABLE user_lists
      ADD CONSTRAINT user_lists_restricted_owner_only
      CHECK (
        add_policy = 'owner_only'
        OR (is_primary = FALSE AND visibility = 'public')
      )
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE user_lists
      DROP CONSTRAINT IF EXISTS user_lists_restricted_owner_only
    SQL
  end
end
