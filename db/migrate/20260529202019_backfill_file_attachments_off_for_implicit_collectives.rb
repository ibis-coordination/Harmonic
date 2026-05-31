# Pins file_attachments to explicit false on collectives that were reading the
# old default (true). The default flips to false in this release so the flag
# can serve as a paid-tier trigger; without this backfill, every existing
# collective would silently move to the paid tier on the next billing
# reconciliation.
#
# Only touches collectives whose feature_flags hash does NOT have an
# explicit "file_attachments" key. Collectives that explicitly opted in
# or out keep their value.
#
# Also clears the legacy settings["allow_file_uploads"] flag on the same
# collectives so the legacy cascade fallback in Collective#file_attachments_enabled?
# can't re-enable file_attachments inadvertently. Explicit feature_flag value
# takes precedence regardless, but keeping the legacy field consistent avoids
# confusion.
#
# Idempotent: safe to re-run. Has no effect on collectives with an explicit
# feature_flags value.
class BackfillFileAttachmentsOffForImplicitCollectives < ActiveRecord::Migration[7.2]
  def up
    Collective.find_each do |collective|
      settings = collective.settings || {}
      flags = settings["feature_flags"] || {}
      next if flags.key?("file_attachments")

      flags["file_attachments"] = false
      settings["feature_flags"] = flags
      settings["allow_file_uploads"] = false
      collective.update_columns(settings: settings)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Cannot tell which collectives were originally implicit vs explicit-false."
  end
end
