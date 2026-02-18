# frozen_string_literal: true

class RenameCollectiveProxyToCollectiveIdentity < ActiveRecord::Migration[7.0]
  def up
    # Rename the column on collectives table
    rename_column :collectives, :proxy_user_id, :identity_user_id

    # Update the user_type enum value
    execute "UPDATE users SET user_type = 'collective_identity' WHERE user_type = 'collective_proxy';"
  end

  def down
    rename_column :collectives, :identity_user_id, :proxy_user_id
    execute "UPDATE users SET user_type = 'collective_proxy' WHERE user_type = 'collective_identity';"
  end
end
