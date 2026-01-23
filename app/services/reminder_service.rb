# typed: true

class ReminderService
  extend T::Sig

  # Limits to prevent abuse
  MAX_REMINDERS_PER_USER = 50
  MAX_REMINDERS_PER_HOUR = 10
  MAX_SCHEDULING_DAYS = 90

  # Custom error classes
  class ReminderError < StandardError; end
  class ReminderLimitExceeded < ReminderError; end
  class ReminderRateLimitExceeded < ReminderError; end
  class ReminderSchedulingError < ReminderError; end

  sig do
    params(
      user: User,
      title: String,
      scheduled_for: Time,
      body: T.nilable(String),
      url: T.nilable(String),
    ).returns(Notification)
  end
  def self.create!(user:, title:, scheduled_for:, body: nil, url: nil)
    tenant = Tenant.find_by(id: Tenant.current_id)
    raise ArgumentError, "No current tenant" unless tenant

    validate_limits!(user, scheduled_for)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: "reminder",
      title: title,
      body: body&.truncate(200),
      url: url,
    )

    channels = user.tenant_user&.notification_channels_for("reminder") || ["in_app"]

    channels.each do |channel|
      NotificationRecipient.create!(
        notification: notification,
        user: user,
        channel: channel,
        status: "pending",
        scheduled_for: scheduled_for,
      )
    end

    notification
  end

  sig { params(notification_recipient: NotificationRecipient).void }
  def self.delete!(notification_recipient)
    notification = notification_recipient.notification
    notification_recipient.destroy!

    # If no recipients left, destroy the notification too
    notification.destroy! if notification.notification_recipients.empty?
  end

  sig { params(user: User).returns(ActiveRecord::Relation) }
  def self.scheduled_for(user)
    NotificationRecipient
      .joins(:notification)
      .where(user: user, channel: "in_app")
      .where(notifications: { notification_type: "reminder" })
      .scheduled
      .includes(:notification)
      .order(:scheduled_for)
  end

  sig { params(user: User, scheduled_time: Time).void }
  def self.validate_limits!(user, scheduled_time)
    # Check total reminder count
    current_count = scheduled_for(user).count
    if current_count >= MAX_REMINDERS_PER_USER
      raise ReminderLimitExceeded, "Maximum #{MAX_REMINDERS_PER_USER} scheduled reminders allowed"
    end

    # Check creation rate
    recent_count = NotificationRecipient
      .joins(:notification)
      .where(user: user)
      .where(notifications: { notification_type: "reminder" })
      .where("notification_recipients.created_at > ?", 1.hour.ago)
      .count
    if recent_count >= MAX_REMINDERS_PER_HOUR
      raise ReminderRateLimitExceeded, "Maximum #{MAX_REMINDERS_PER_HOUR} reminders per hour"
    end

    # Check scheduling window
    max_date = MAX_SCHEDULING_DAYS.days.from_now
    if scheduled_time > max_date
      raise ReminderSchedulingError, "Cannot schedule more than #{MAX_SCHEDULING_DAYS} days in future"
    end

    # Must be in the future
    if scheduled_time <= Time.current
      raise ReminderSchedulingError, "scheduled_for must be in the future"
    end
  end
end
