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
  }

  Sidekiq::Cron::Job.load_from_hash(schedule)
end
