class AddScrubbedAtToTenantUsers < ActiveRecord::Migration[7.2]
  def change
    # Per-subdomain deletion is two-phase like global deletion:
    # deletion_requested_at marks the reversible lock, scrubbed_at marks the
    # irreversible per-tenant scrub.
    add_column :tenant_users, :scrubbed_at, :datetime

    add_index :tenant_users, :deletion_requested_at,
              where: "deletion_requested_at IS NOT NULL AND scrubbed_at IS NULL",
              name: "index_tenant_users_on_pending_deletion"
  end
end
