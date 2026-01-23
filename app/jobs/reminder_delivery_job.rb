# typed: true

class ReminderDeliveryJob < ApplicationJob
  extend T::Sig

  queue_as :default

  MAX_DELIVERIES_PER_USER_PER_MINUTE = 5
  MAX_REMINDERS_PER_RUN = 100

  sig { void }
  def perform
    # Find due reminders that are pending
    due_reminders = NotificationRecipient
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
    tenant = notification.tenant

    # Loop prevention: check recent deliveries for this user
    # NOTE: Rate limiting check is not atomic. In rare cases of concurrent job
    # execution, slightly more than MAX_DELIVERIES_PER_USER_PER_MINUTE could be
    # delivered. This is acceptable because:
    # 1. The job runs on a cron schedule (not triggered by events)
    # 2. Concurrent execution for the same user is unlikely
    # 3. The consequence (a few extra deliveries) is minor
    # If this becomes an issue, consider Redis-based distributed rate limiting.
    recent_deliveries = NotificationRecipient
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

    # Set context for event creation
    set_tenant_context(tenant)

    # Find a superagent context for the user
    superagent = find_superagent_for_user(user, tenant)
    unless superagent
      Rails.logger.warn("User #{user.id} has no superagent membership in tenant #{tenant.id}, cannot deliver reminders")
      return
    end

    set_superagent_context(superagent)

    begin
      # Create single batched event to trigger webhooks
      EventService.record!(
        event_type: "reminders.delivered",
        actor: user,
        subject: notification,
        metadata: {
          "reminders" => reminders.map do |nr|
            {
              "id" => nr.notification.id,
              "title" => nr.notification.title,
              "body" => nr.notification.body,
              "scheduled_for" => nr.scheduled_for&.iso8601,
            }
          end,
          "count" => reminders.size,
        },
      )

      # Deliver each notification (in-app)
      reminders.each do |nr|
        NotificationDeliveryJob.perform_now(nr.id)
      end
    ensure
      clear_context
    end
  end

  sig { params(tenant: Tenant).void }
  def set_tenant_context(tenant)
    Tenant.current_subdomain = tenant.subdomain
    Tenant.current_id = tenant.id
    Tenant.current_main_superagent_id = tenant.main_superagent_id
  end

  sig { params(superagent: Superagent).void }
  def set_superagent_context(superagent)
    Thread.current[:superagent_id] = superagent.id
    Thread.current[:superagent_handle] = superagent.handle
  end

  sig { void }
  def clear_context
    Tenant.clear_thread_scope
    Superagent.clear_thread_scope
  end

  sig { params(user: User, tenant: Tenant).returns(T.nilable(Superagent)) }
  def find_superagent_for_user(user, tenant)
    # Find a superagent the user is a member of in this tenant
    membership = SuperagentMember
      .joins(:superagent)
      .where(user: user)
      .where(superagents: { tenant_id: tenant.id })
      .where(archived_at: nil)
      .first

    membership&.superagent
  end
end
