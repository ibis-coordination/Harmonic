class AddAccountClosureStateToUsers < ActiveRecord::Migration[7.2]
  def change
    # Two-phase account closure: close_requested_at marks the reversible
    # close (grace window running); scrubbed_at marks the irreversible scrub.
    add_column :users, :close_requested_at, :datetime
    add_column :users, :scrubbed_at, :datetime
    # Per-subdomain closure state (mirrors the user-level column).
    add_column :tenant_users, :close_requested_at, :datetime

    add_index :users, :close_requested_at,
              where: "close_requested_at IS NOT NULL AND scrubbed_at IS NULL",
              name: "index_users_on_pending_closure"
  end
end
