class ExtendTrusteePermissions < ActiveRecord::Migration[7.0]
  def change
    # Add tenant reference - TrusteePermission needs tenant context for multi-tenancy
    add_reference :trustee_permissions, :tenant, null: true, foreign_key: true, type: :uuid

    # Add acceptance workflow columns
    add_column :trustee_permissions, :accepted_at, :datetime
    add_column :trustee_permissions, :declined_at, :datetime
    add_column :trustee_permissions, :revoked_at, :datetime

    # Add studio scoping (defaults to "all" studios)
    add_column :trustee_permissions, :studio_scope, :jsonb, default: { "mode" => "all" }

    # Add indexes for efficient queries
    add_index :trustee_permissions, :accepted_at

    # Unique index for active permissions (only one active permission per granting_user/trusted_user pair)
    add_index :trustee_permissions, [:granting_user_id, :trusted_user_id],
              unique: true,
              where: "revoked_at IS NULL AND declined_at IS NULL",
              name: "idx_active_trustee_permissions"
  end
end
