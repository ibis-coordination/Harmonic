# typed: false
# frozen_string_literal: true

# Configure recurring jobs using sidekiq-cron
#
# Jobs are loaded when Sidekiq server starts.
# See: https://github.com/sidekiq-cron/sidekiq-cron

Sidekiq.configure_server do |_config|
  schedule = {
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
  }

  Sidekiq::Cron::Job.load_from_hash(schedule)
end
