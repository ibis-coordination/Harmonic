# typed: true
# frozen_string_literal: true

# Daily sweeper that tombstones soft-deleted Notes whose grace period has
# expired. Runs across all tenants without setting tenant context — each
# tombstone is wrapped in its own transaction inside
# DataDeletionManager.system_tombstone_note! so a failure on one note
# doesn't block the rest of the batch.
#
# Scoped to Note only. Decision and Commitment soft-delete is open-ended
# (they don't opt into participates_in_hard_delete) so they never have
# hard_delete_after set and won't show up in this query.
class HardDeleteExpiredRecordsJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  sig { void }
  def perform
    eligible = Note.unscoped_for_system_job
      .where.not(deleted_at: nil)
      .where(tombstoned_at: nil)
      .where("hard_delete_after < ?", Time.current)

    eligible.find_each do |note|
      begin
        DataDeletionManager.system_tombstone_note!(note: note)
      rescue StandardError => e
        Rails.logger.error("HardDeleteExpiredRecordsJob: failed to tombstone Note ##{note.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
