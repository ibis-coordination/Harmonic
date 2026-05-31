# Adds an explicit `tier` state machine column to collectives, replacing the
# previous implicit "enabling a paid feature moves the collective to paid"
# model. All existing collectives backfill to `free` regardless of current
# feature state — explicit upgrade becomes a deliberate user action via the
# new POST /collectives/:handle/upgrade endpoint.
class AddTierToCollectives < ActiveRecord::Migration[7.2]
  def change
    add_column :collectives, :tier, :string, null: false, default: "free"
    add_index :collectives, :tier
  end
end
