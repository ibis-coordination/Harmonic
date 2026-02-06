class AddTruncatedIdToTrusteePermissions < ActiveRecord::Migration[7.0]
  def up
    # Add a generated column that automatically derives truncated_id from id
    execute <<~SQL
      ALTER TABLE trustee_permissions
      ADD COLUMN truncated_id character varying
      GENERATED ALWAYS AS (LEFT(id::text, 8)) STORED NOT NULL;
    SQL
    add_index :trustee_permissions, :truncated_id, unique: true
  end

  def down
    remove_index :trustee_permissions, :truncated_id
    remove_column :trustee_permissions, :truncated_id
  end
end
