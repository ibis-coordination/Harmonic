# typed: false
# frozen_string_literal: true

# Configure recurring jobs using sidekiq-cron
#
# Jobs are loaded when Sidekiq server starts.
# See: https://github.com/sidekiq-cron/sidekiq-cron
#
# The schedule lives in a top-level constant (rather than inline in the
# configure_server block, which only runs in the Sidekiq server process)
# so tests can assert entries exist and reference real job classes.
SIDEKIQ_CRON_SCHEDULE = {
  "automation_scheduler" => {
    "cron" => "* * * * *", # Every minute
    "class" => "AutomationSchedulerJob",
    "description" => "Process scheduled automation rules",
  },
  "reminder_delivery" => {
    "cron" => "* * * * *", # Every minute
    "class" => "ReminderDeliveryJob",
    "description" => "Deliver due reminders",
  },
  "deadline_event" => {
    "cron" => "* * * * *", # Every minute
    "class" => "DeadlineEventJob",
    "description" => "Fire events when decision/commitment deadlines pass",
  },
  "orphaned_task_sweep" => {
    "cron" => "*/10 * * * *", # Every 10 minutes
    "class" => "OrphanedTaskSweepJob",
    "description" => "Mark stuck agent task runs as failed",
  },
  "billing_reconciliation" => {
    "cron" => "0 2 * * *", # Daily at 2 AM
    "class" => "BillingReconciliationJob",
    "description" => "Reconcile Stripe subscription quantities and recover stuck pending resources",
  },
  "cleanup_expired_exports" => {
    "cron" => "0 3 * * *", # Daily at 3 AM
    "class" => "CleanupExpiredExportsJob",
    "description" => "Purge expired data export files",
  },
  "sweep_stuck_data_imports" => {
    "cron" => "0 * * * *", # Hourly
    "class" => "SweepStuckDataImportsJob",
    "description" => "Mark stuck data imports as failed",
  },
  "hard_delete_expired_records" => {
    "cron" => "30 3 * * *", # Daily at 3:30 AM
    "class" => "HardDeleteExpiredRecordsJob",
    "description" => "Tombstone soft-deleted Notes whose grace period has expired",
  },
  "purge_dismissed_notifications" => {
    "cron" => "0 4 * * *", # Daily at 4 AM
    "class" => "PurgeDismissedNotificationsJob",
    "description" => "Delete long-dismissed notification recipients and orphaned notifications",
  },
  "cleanup_abandoned_bridge_setups" => {
    "cron" => "15 * * * *", # Hourly at :15
    "class" => "CleanupAbandonedBridgeSetupsJob",
    "description" => "Destroy expired-unfinished harmonic-bridge setups + their orphaned token + rule",
  },
}.freeze

Sidekiq.configure_server do |_config|
  Sidekiq::Cron::Job.load_from_hash(SIDEKIQ_CRON_SCHEDULE)
end
