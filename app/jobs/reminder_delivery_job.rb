# typed: true
# frozen_string_literal: true

# ReminderDeliveryJob processes due reminders across all tenants.
# It's a SystemJob because it queries reminders globally, then processes
# each batch within its tenant's context.
class ReminderDeliveryJob < SystemJob
  extend T::Sig

  queue_as :default

  MAX_DELIVERIES_PER_USER_PER_MINUTE = 5
  MAX_REMINDERS_PER_RUN = 100

  sig { void }
  def perform
    # Find due reminders that are pending (across all tenants)
    due_reminders = NotificationRecipient.unscoped_for_system_job
      .joins(:notification)
      .where(notifications: { notification_type: "reminder" })
      .due
      .where(status: "pending")
      .includes(:notification, :user)
      .limit(MAX_REMINDERS_PER_RUN)
      .order(:scheduled_for)

    # Group by user_id and scheduled_for for batching
    batches = due_reminders.group_by { |nr| [nr.user_id, nr.scheduled_for] }

    batches.each do |(_user_id, _scheduled_for), reminders|
      deliver_batch(reminders)
    end
  end

  private

  sig { params(reminders: T::Array[NotificationRecipient]).void }
  def deliver_batch(reminders)
    return if reminders.empty?

    first = reminders.first
    return unless first

    user = first.user
    notification = first.notification
    return unless user && notification

    tenant = notification.tenant
    return unless tenant

    # Loop prevention: check recent deliveries for this user
    # NOTE: Rate limiting check is not atomic. In rare cases of concurrent job
    # execution, slightly more than MAX_DELIVERIES_PER_USER_PER_MINUTE could be
    # delivered. This is acceptable because:
    # 1. The job runs on a cron schedule (not triggered by events)
    # 2. Concurrent execution for the same user is unlikely
    # 3. The consequence (a few extra deliveries) is minor
    # If this becomes an issue, consider Redis-based distributed rate limiting.
    recent_deliveries = NotificationRecipient.unscoped_for_system_job
      .joins(:notification)
      .where(user: user)
      .where(notifications: { notification_type: "reminder" })
      .where(status: "delivered")
      .where("notification_recipients.delivered_at > ?", 1.minute.ago)
      .count

    if recent_deliveries >= MAX_DELIVERIES_PER_USER_PER_MINUTE
      Rails.logger.warn("Reminder loop detected for user #{user.id}, rate limiting batch of #{reminders.size}")
      reminders.each { |nr| nr.update!(status: "rate_limited") }
      return
    end

    # Find a collective context for the user
    collective = find_collective_for_user(user, tenant)
    unless collective
      Rails.logger.warn("User #{user.id} has no collective membership in tenant #{tenant.id}, cannot deliver reminders")
      return
    end

    # Process batch with tenant and collective context
    with_tenant_and_collective_context(tenant, collective) do
      # Create single batched event to trigger webhooks
      EventService.record!(
        event_type: "reminders.delivered",
        actor: user,
        subject: notification,
        metadata: {
          "reminders" => reminders.filter_map do |nr|
            notif = nr.notification
            next unless notif

            {
              "id" => notif.id,
              "title" => notif.title,
              "body" => notif.body,
              "scheduled_for" => nr.scheduled_for&.iso8601,
            }
          end,
          "count" => reminders.size,
        }
      )

      # Deliver each notification (in-app)
      reminders.each do |nr|
        NotificationDeliveryJob.perform_now(nr.id)
      end
    end
  end

  sig { params(user: User, tenant: Tenant).returns(T.nilable(Collective)) }
  def find_collective_for_user(user, tenant)
    # Find a collective the user is a member of in this tenant
    membership = CollectiveMember.unscoped_for_system_job
      .joins(:collective)
      .where(user: user)
      .where(collectives: { tenant_id: tenant.id })
      .where(archived_at: nil)
      .first

    membership&.collective
  end
end
