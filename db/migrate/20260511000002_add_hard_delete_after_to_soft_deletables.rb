# typed: false

class AddHardDeleteAfterToSoftDeletables < ActiveRecord::Migration[7.2]
  TABLES = [:notes, :decisions, :commitments].freeze

  def up
    TABLES.each do |t|
      add_column t, :hard_delete_after, :datetime
      add_index t, :hard_delete_after
    end

    # Existing soft-deleted rows: schedule them for hard-delete at the same
    # cutoff new soft-deletes will use (30 days post-deletion). Most existing
    # rows will already be past that cutoff and will be hard-deleted on the
    # first job run, which is the intended behavior — their content was
    # scrubbed under the old soft_delete! semantics so nothing is preserved.
    TABLES.each do |t|
      execute(<<~SQL.squish)
        UPDATE #{t}
        SET hard_delete_after = deleted_at + INTERVAL '30 days'
        WHERE deleted_at IS NOT NULL
      SQL
    end
  end

  def down
    TABLES.each do |t|
      remove_index t, :hard_delete_after
      remove_column t, :hard_delete_after
    end
  end
end
