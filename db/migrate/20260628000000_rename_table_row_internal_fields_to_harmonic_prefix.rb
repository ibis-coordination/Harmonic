# Renames the three internal bookkeeping keys stored on each table-note row from
# their single-underscore names to the reserved `_harmonic_` namespace:
#
#   _id         -> _harmonic_row_id
#   _created_by -> _harmonic_created_by
#   _created_at -> _harmonic_created_at
#
# The single-underscore prefix is too generic to safely reserve (CSV exports
# routinely contain columns literally named `_id`). The `_harmonic_` prefix is
# now reserved instead. PR #283 made `_id` agent-visible for the first time via
# query_rows, so this is the last moment a clean rename has no external
# consumers to break.
#
# Renaming these keys does not change a note's rendered `text`: the formatter
# only emits user-defined columns (and, opt-in, the row id), never the raw
# storage keys — so `update_columns` is sufficient and intentionally skips
# validations/callbacks, which is the right behavior for a system-job backfill.
#
# Idempotent: a row that already carries `_harmonic_row_id` is left untouched,
# so the migration is safe to re-run and safe to run while old/new code overlap.
class RenameTableRowInternalFieldsToHarmonicPrefix < ActiveRecord::Migration[7.2]
  KEY_RENAMES = {
    "_id" => "_harmonic_row_id",
    "_created_by" => "_harmonic_created_by",
    "_created_at" => "_harmonic_created_at",
  }.freeze

  def up
    Note.unscoped_for_system_job.where(subtype: "table").find_each do |note|
      data = note.table_data
      next unless data.is_a?(Hash)

      rows = data["rows"]
      next unless rows.is_a?(Array) && rows.any?

      changed = false
      new_rows = rows.map do |row|
        next row unless row.is_a?(Hash)
        next row if row.key?("_harmonic_row_id") # already migrated

        new_row = row.dup
        KEY_RENAMES.each do |old_key, new_key|
          next unless new_row.key?(old_key)
          new_row[new_key] = new_row.delete(old_key)
          changed = true
        end
        new_row
      end

      next unless changed

      new_data = data.merge("rows" => new_rows)
      ActiveRecord::Base.transaction do
        note.update_columns(table_data: new_data)
      end
    rescue StandardError => e
      Rails.logger.warn(
        "RenameTableRowInternalFieldsToHarmonicPrefix: skipping note #{note.id}: #{e.message}"
      )
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Reversing would conflict with rows legitimately created under the new keys."
  end
end
