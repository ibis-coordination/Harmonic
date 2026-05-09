# typed: true
# frozen_string_literal: true

# Marks DataImport rows that have been stuck in a non-terminal status for too
# long as failed.
#
# Background: when a Sidekiq worker dies mid-import (OOM, hard kill, container
# restart, or a bug in the rescue path) the row is left in pending/validating/
# importing. Sidekiq's retry sees the non-pending status and returns early via
# CollectiveImportJob's status guard, so the row stays stuck and the admin
# can't tell the import is dead.
#
# This sweeper is the safety net.
#
# Runs hourly via sidekiq-cron.
class SweepStuckDataImportsJob < SystemJob
  extend T::Sig

  STUCK_THRESHOLD = 1.hour

  sig { void }
  def perform
    cutoff = STUCK_THRESHOLD.ago

    stuck = DataImport.unscoped_for_system_job
      .where(status: ["pending", "validating", "importing"])
      .where("COALESCE(started_at, created_at) < ?", cutoff)

    stuck.find_each do |data_import|
      data_import.update_columns(
        status: "failed",
        error_message: "Import did not complete within #{STUCK_THRESHOLD.inspect} — worker likely died before the rescue path could mark the import as failed.",
        updated_at: Time.current,
      )
      Rails.logger.warn(
        "[SweepStuckDataImports] Marked DataImport #{data_import.id} as failed " \
        "(was #{data_import.status_was || data_import.status}, started_at: #{data_import.started_at}, " \
        "tenant: #{data_import.tenant_id})",
      )
    end
  end
end
