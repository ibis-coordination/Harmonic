class AddAccountDeletionStateToUsers < ActiveRecord::Migration[7.2]
  def change
    # Two-phase account deletion: deletion_requested_at marks the reversible
    # lock (grace period running); scrubbed_at marks the irreversible scrub.
    add_column :users, :deletion_requested_at, :datetime
    add_column :users, :scrubbed_at, :datetime
    # Per-subdomain deletion state (mirrors the user-level column).
    add_column :tenant_users, :deletion_requested_at, :datetime

    add_index :users, :deletion_requested_at,
              where: "deletion_requested_at IS NOT NULL AND scrubbed_at IS NULL",
              name: "index_users_on_pending_deletion"
  end
end
