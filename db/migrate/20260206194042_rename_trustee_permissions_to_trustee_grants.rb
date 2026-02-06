class RenameTrusteePermissionsToTrusteeGrants < ActiveRecord::Migration[7.0]
  def up
    # Use a single SQL statement to rename all at once
    execute <<~SQL
      ALTER TABLE trustee_permissions RENAME TO trustee_grants;
      ALTER INDEX idx_active_trustee_permissions RENAME TO idx_active_trustee_grants;
      ALTER INDEX index_trustee_permissions_on_accepted_at RENAME TO index_trustee_grants_on_accepted_at;
      ALTER INDEX index_trustee_permissions_on_granting_user_id RENAME TO index_trustee_grants_on_granting_user_id;
      ALTER INDEX index_trustee_permissions_on_tenant_id RENAME TO index_trustee_grants_on_tenant_id;
      ALTER INDEX index_trustee_permissions_on_truncated_id RENAME TO index_trustee_grants_on_truncated_id;
      ALTER INDEX index_trustee_permissions_on_trusted_user_id RENAME TO index_trustee_grants_on_trusted_user_id;
      ALTER INDEX index_trustee_permissions_on_trustee_user_id RENAME TO index_trustee_grants_on_trustee_user_id;
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE trustee_grants RENAME TO trustee_permissions;
      ALTER INDEX idx_active_trustee_grants RENAME TO idx_active_trustee_permissions;
      ALTER INDEX index_trustee_grants_on_accepted_at RENAME TO index_trustee_permissions_on_accepted_at;
      ALTER INDEX index_trustee_grants_on_granting_user_id RENAME TO index_trustee_permissions_on_granting_user_id;
      ALTER INDEX index_trustee_grants_on_tenant_id RENAME TO index_trustee_permissions_on_tenant_id;
      ALTER INDEX index_trustee_grants_on_truncated_id RENAME TO index_trustee_permissions_on_truncated_id;
      ALTER INDEX index_trustee_grants_on_trusted_user_id RENAME TO index_trustee_permissions_on_trusted_user_id;
      ALTER INDEX index_trustee_grants_on_trustee_user_id RENAME TO index_trustee_permissions_on_trustee_user_id;
    SQL
  end
end
