# Track who archived a collective (in addition to when, via archived_at).
# Required for accountability now that archive is gated behind reverification
# and writes to the security audit log.
#
# Going forward, Collective#archive! sets archived_by_id alongside
# archived_at, and Collective#unarchive! clears both. For collectives
# archived before this migration, archived_by_id is backfilled to
# created_by_id as a best-effort attribution (the creator is the only user
# the model authorizes to archive).
#
# The FK uses ON DELETE RESTRICT to make the audit trail hard to break: any
# future hard-delete path for users must first detach (unarchive) collectives
# they archived. Today user "deletion" is a PII scrub via
# DataDeletionManager#delete_user! that leaves the users row in place, so
# this restriction never fires in practice — it's insurance for a future
# force_delete that may eventually ship.
#
# The column is nullable because non-archived collectives have no archiver.
# Invariant the model enforces: archived_by_id IS NOT NULL iff archived_at
# IS NOT NULL.
class AddArchivedByIdToCollectives < ActiveRecord::Migration[7.2]
  def up
    add_column :collectives, :archived_by_id, :uuid, null: true
    add_index :collectives, :archived_by_id, where: "archived_by_id IS NOT NULL"

    # Best-effort backfill for legacy archived rows.
    execute <<~SQL
      UPDATE collectives
      SET archived_by_id = created_by_id
      WHERE archived_at IS NOT NULL AND archived_by_id IS NULL
    SQL

    # Legacy archived collectives may still carry tier = 'paid' from before
    # the auto-downgrade-on-archive behavior. Drop them to 'free' so a future
    # unarchive doesn't silently resume billing.
    execute <<~SQL
      UPDATE collectives
      SET tier = 'free'
      WHERE archived_at IS NOT NULL AND tier <> 'free'
    SQL

    add_foreign_key :collectives, :users, column: :archived_by_id, on_delete: :restrict
  end

  def down
    remove_foreign_key :collectives, column: :archived_by_id
    remove_index :collectives, :archived_by_id
    remove_column :collectives, :archived_by_id
  end
end
