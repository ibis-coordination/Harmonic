class RenameTrusteeToSuperagentProxy < ActiveRecord::Migration[7.0]
  def up
    # Rename column in superagents table
    rename_column :superagents, :trustee_user_id, :proxy_user_id

    # Update user_type values from 'trustee' to 'superagent_proxy'
    execute "UPDATE users SET user_type = 'superagent_proxy' WHERE user_type = 'trustee'"
  end

  def down
    rename_column :superagents, :proxy_user_id, :trustee_user_id
    execute "UPDATE users SET user_type = 'trustee' WHERE user_type = 'superagent_proxy'"
  end
end
