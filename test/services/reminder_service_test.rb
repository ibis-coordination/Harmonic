require "test_helper"

class ReminderServiceTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
  end

  def teardown
    Collective.clear_thread_scope
  end

  # === Create Tests ===

  test "create! creates notification with reminder type" do
    notification = ReminderService.create!(
      user: @user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now,
    )

    assert_equal "reminder", notification.notification_type
    assert_equal "Test reminder", notification.title
    assert_equal @tenant, notification.tenant
  end

  test "create! creates notification_recipient with scheduled_for" do
    scheduled_time = 1.day.from_now
    notification = ReminderService.create!(
      user: @user,
      title: "Test reminder",
      scheduled_for: scheduled_time,
    )

    nr = notification.notification_recipients.first
    assert_equal @user, nr.user
    assert_in_delta scheduled_time, nr.scheduled_for, 1.second
    assert_equal "pending", nr.status
    assert_equal "in_app", nr.channel
  end

  test "create! creates notification without event" do
    notification = ReminderService.create!(
      user: @user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now,
    )

    assert_nil notification.event
  end

  test "create! truncates body to 200 characters" do
    long_body = "a" * 300
    notification = ReminderService.create!(
      user: @user,
      title: "Test",
      body: long_body,
      scheduled_for: 1.day.from_now,
    )

    assert_equal 200, notification.body.length
    assert notification.body.end_with?("...")
  end

  test "create! sets url when provided" do
    notification = ReminderService.create!(
      user: @user,
      title: "Check this out",
      scheduled_for: 1.day.from_now,
      url: "/studios/test/n/abc123",
    )

    assert_equal "/studios/test/n/abc123", notification.url
  end

  # === Scheduled For Tests ===

  test "scheduled_for returns user's scheduled reminders" do
    ReminderService.create!(user: @user, title: "R1", scheduled_for: 1.day.from_now)
    ReminderService.create!(user: @user, title: "R2", scheduled_for: 2.days.from_now)

    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    ReminderService.create!(user: other_user, title: "Other", scheduled_for: 1.day.from_now)

    reminders = ReminderService.scheduled_for(@user)
    assert_equal 2, reminders.count
    assert_equal "R1", reminders.first.notification.title
  end

  test "scheduled_for excludes past reminders" do
    ReminderService.create!(user: @user, title: "Future", scheduled_for: 1.day.from_now)

    # Create a past one by manipulating scheduled_for directly
    notification = ReminderService.create!(user: @user, title: "Past", scheduled_for: 1.day.from_now)
    notification.notification_recipients.first.update!(scheduled_for: 1.day.ago)

    reminders = ReminderService.scheduled_for(@user)
    assert_equal 1, reminders.count
    assert_equal "Future", reminders.first.notification.title
  end

  test "scheduled_for orders by scheduled_for ascending" do
    ReminderService.create!(user: @user, title: "Later", scheduled_for: 3.days.from_now)
    ReminderService.create!(user: @user, title: "Sooner", scheduled_for: 1.day.from_now)
    ReminderService.create!(user: @user, title: "Middle", scheduled_for: 2.days.from_now)

    reminders = ReminderService.scheduled_for(@user)
    assert_equal "Sooner", reminders.first.notification.title
    assert_equal "Later", reminders.last.notification.title
  end

  # === Delete Tests ===

  test "delete! removes notification_recipient and notification" do
    notification = ReminderService.create!(
      user: @user,
      title: "To delete",
      scheduled_for: 1.day.from_now,
    )
    nr = notification.notification_recipients.first

    ReminderService.delete!(nr)

    assert_raises(ActiveRecord::RecordNotFound) { nr.reload }
    assert_raises(ActiveRecord::RecordNotFound) { notification.reload }
  end

  test "delete! keeps notification if other recipients exist" do
    notification = ReminderService.create!(
      user: @user,
      title: "To delete partially",
      scheduled_for: 1.day.from_now,
    )

    # Add another recipient
    other_user = create_user(name: "Other User Delete")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)
    NotificationRecipient.create!(
      notification: notification,
      user: other_user,
      channel: "in_app",
      status: "pending",
      scheduled_for: 1.day.from_now,
    )

    nr = notification.notification_recipients.where(user: @user).first
    ReminderService.delete!(nr)

    assert_raises(ActiveRecord::RecordNotFound) { nr.reload }
    # Notification should still exist
    assert_nothing_raised { notification.reload }
  end

  # === Validation Tests ===

  test "create! raises ReminderLimitExceeded when user has too many reminders" do
    # Create reminders directly in the database to bypass rate limit for this test
    # This tests that the limit check correctly counts scheduled reminders
    notification = Notification.create!(
      tenant: @tenant,
      notification_type: "reminder",
      title: "Bulk reminder",
    )

    ReminderService::MAX_REMINDERS_PER_USER.times do |i|
      NotificationRecipient.create!(
        notification: notification,
        user: @user,
        channel: "in_app",
        status: "pending",
        scheduled_for: (i + 1).days.from_now,
        created_at: (i + 1).hours.ago, # Spread out creation times to avoid rate limit
      )
    end

    assert_raises(ReminderService::ReminderLimitExceeded) do
      ReminderService.create!(
        user: @user,
        title: "One too many",
        scheduled_for: 1.day.from_now,
      )
    end
  end

  test "create! raises ReminderRateLimitExceeded when creating too many per hour" do
    ReminderService::MAX_REMINDERS_PER_HOUR.times do |i|
      ReminderService.create!(
        user: @user,
        title: "Rapid reminder #{i}",
        scheduled_for: (i + 1).days.from_now,
      )
    end

    assert_raises(ReminderService::ReminderRateLimitExceeded) do
      ReminderService.create!(
        user: @user,
        title: "Too fast",
        scheduled_for: 1.day.from_now,
      )
    end
  end

  test "create! raises ReminderSchedulingError when scheduling too far in future" do
    assert_raises(ReminderService::ReminderSchedulingError) do
      ReminderService.create!(
        user: @user,
        title: "Way too far",
        scheduled_for: (ReminderService::MAX_SCHEDULING_DAYS + 1).days.from_now,
      )
    end
  end

  test "create! raises ReminderSchedulingError when scheduling in the past" do
    assert_raises(ReminderService::ReminderSchedulingError) do
      ReminderService.create!(
        user: @user,
        title: "Already passed",
        scheduled_for: 1.hour.ago,
      )
    end
  end

  test "create! raises ArgumentError when no current tenant" do
    Tenant.current_id = nil

    assert_raises(ArgumentError) do
      ReminderService.create!(
        user: @user,
        title: "No tenant",
        scheduled_for: 1.day.from_now,
      )
    end
  end
end
