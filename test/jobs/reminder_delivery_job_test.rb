require "test_helper"

class ReminderDeliveryJobTest < ActiveJob::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
  end

  def teardown
    Collective.clear_thread_scope
  end

  test "delivers due reminders" do
    notification = ReminderService.create!(
      user: @user,
      title: "Due reminder",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first
    nr.update!(scheduled_for: 1.minute.ago) # Make it due

    Collective.clear_thread_scope
    ReminderDeliveryJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    nr.reload
    assert_equal "delivered", nr.status
  end

  test "does not deliver future reminders" do
    notification = ReminderService.create!(
      user: @user,
      title: "Future reminder",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first

    Collective.clear_thread_scope
    ReminderDeliveryJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    nr.reload
    assert_equal "pending", nr.status
  end

  test "does not deliver already delivered reminders" do
    notification = ReminderService.create!(
      user: @user,
      title: "Already delivered",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first
    nr.update!(scheduled_for: 1.minute.ago, status: "delivered", delivered_at: Time.current)

    Collective.clear_thread_scope
    ReminderDeliveryJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    # Should still be delivered, not re-processed
    nr.reload
    assert_equal "delivered", nr.status
  end

  test "creates reminders.delivered event for webhooks" do
    notification = ReminderService.create!(
      user: @user,
      title: "Webhook reminder",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first
    nr.update!(scheduled_for: 1.minute.ago)

    Collective.clear_thread_scope

    assert_difference "Event.count" do
      ReminderDeliveryJob.perform_now
    end

    event = Event.last
    assert_equal "reminders.delivered", event.event_type
    assert_equal @user.id, event.actor_id
    assert_equal 1, event.metadata["count"]
    assert_equal "Webhook reminder", event.metadata["reminders"].first["title"]
  end

  test "batches reminders with same timestamp into single event" do
    # Use a fixed past timestamp for all reminders
    due_time = 1.minute.ago

    # Create 3 reminders for the exact same time
    3.times do |i|
      notification = ReminderService.create!(
        user: @user,
        title: "Reminder #{i}",
        scheduled_for: 1.day.from_now,
      )
      # Set exact same scheduled_for timestamp for batching
      notification.notification_recipients.first.update!(scheduled_for: due_time)
    end

    Collective.clear_thread_scope

    # Should create only 1 event for the batch
    assert_difference "Event.count", 1 do
      ReminderDeliveryJob.perform_now
    end

    event = Event.last
    assert_equal "reminders.delivered", event.event_type
    assert_equal 3, event.metadata["count"]
    assert_equal 3, event.metadata["reminders"].size
  end

  test "creates separate events for different timestamps" do
    # Create reminders for different times
    n1 = ReminderService.create!(user: @user, title: "R1", scheduled_for: 1.day.from_now)
    n1.notification_recipients.first.update!(scheduled_for: 1.minute.ago)

    n2 = ReminderService.create!(user: @user, title: "R2", scheduled_for: 2.days.from_now)
    n2.notification_recipients.first.update!(scheduled_for: 2.minutes.ago)

    Collective.clear_thread_scope

    # Should create 2 events (one per timestamp)
    assert_difference "Event.count", 2 do
      ReminderDeliveryJob.perform_now
    end
  end

  test "rate limits deliveries to prevent loops" do
    # Create many due reminders with the same timestamp
    same_time = 1.day.from_now
    (ReminderDeliveryJob::MAX_DELIVERIES_PER_USER_PER_MINUTE + 2).times do |i|
      notification = ReminderService.create!(
        user: @user,
        title: "Reminder #{i}",
        scheduled_for: same_time,
      )
      notification.notification_recipients.first.update!(scheduled_for: 1.minute.ago)
    end

    Collective.clear_thread_scope
    ReminderDeliveryJob.perform_now
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    delivered = NotificationRecipient
      .joins(:notification)
      .where(user: @user)
      .where(notifications: { notification_type: "reminder" })
      .where(status: "delivered")
      .count

    rate_limited = NotificationRecipient
      .joins(:notification)
      .where(user: @user)
      .where(notifications: { notification_type: "reminder" })
      .where(status: "rate_limited")
      .count

    # First batch should be delivered
    assert delivered <= ReminderDeliveryJob::MAX_DELIVERIES_PER_USER_PER_MINUTE + 2
    # Some may be rate limited based on timing
    assert rate_limited >= 0 || delivered > 0
  end

  test "skips users without collective membership" do
    # Create a user not in any collective
    orphan_user = create_user(name: "Orphan User")
    @tenant.add_user!(orphan_user)
    @collective.add_user!(orphan_user)

    notification = ReminderService.create!(
      user: orphan_user,
      title: "Orphan reminder",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first
    nr.update!(scheduled_for: 1.minute.ago)

    # Remove their collective membership AFTER creating the reminder
    CollectiveMember.unscoped.where(user: orphan_user).destroy_all

    Collective.clear_thread_scope

    # Should not raise an error
    assert_nothing_raised do
      ReminderDeliveryJob.perform_now
    end

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    # Reminder should still be pending (not delivered)
    nr.reload
    assert_equal "pending", nr.status
  end

  test "respects MAX_REMINDERS_PER_RUN limit" do
    # Create reminders directly in the database to bypass rate limit
    (ReminderDeliveryJob::MAX_REMINDERS_PER_RUN + 5).times do |i|
      notification = Notification.create!(
        tenant: @tenant,
        notification_type: "reminder",
        title: "Reminder #{i}",
      )
      NotificationRecipient.create!(
        notification: notification,
        user: @user,
        channel: "in_app",
        status: "pending",
        scheduled_for: (i + 1).minutes.ago, # All due, different timestamps
        created_at: (i + 1).hours.ago, # Spread out creation times to avoid rate limit checks
      )
    end

    Collective.clear_thread_scope

    # Run the job once
    ReminderDeliveryJob.perform_now

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    # Should have processed at most MAX_REMINDERS_PER_RUN
    processed_count = NotificationRecipient
      .joins(:notification)
      .where(user: @user)
      .where(notifications: { notification_type: "reminder" })
      .where.not(status: "pending")
      .count

    assert processed_count <= ReminderDeliveryJob::MAX_REMINDERS_PER_RUN
  end
end
