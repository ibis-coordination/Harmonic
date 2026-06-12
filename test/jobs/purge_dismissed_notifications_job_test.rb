# typed: false

require "test_helper"

class PurgeDismissedNotificationsJobTest < ActiveJob::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
  end

  def teardown
    Collective.clear_thread_scope
    Tenant.current_id = nil
  end

  def create_recipient(title: "Test", dismissed_ago: nil, created_ago: 2.days)
    notification = Notification.create!(
      tenant: @tenant,
      notification_type: "mention",
      title: title
    )
    notification.update_columns(created_at: created_ago.ago)

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: @user,
      channel: "in_app",
      status: "delivered"
    )
    if dismissed_ago
      recipient.update_columns(
        dismissed_at: dismissed_ago.ago,
        read_at: dismissed_ago.ago,
        status: "dismissed",
        created_at: dismissed_ago.ago
      )
    end
    recipient
  end

  test "deletes recipients dismissed longer ago than the retention period" do
    old = create_recipient(title: "Old dismissed", dismissed_ago: 91.days)
    recent = create_recipient(title: "Recently dismissed", dismissed_ago: 10.days)

    Tenant.current_id = nil
    PurgeDismissedNotificationsJob.perform_now

    assert_not NotificationRecipient.unscoped_for_system_job.exists?(old.id)
    assert NotificationRecipient.unscoped_for_system_job.exists?(recent.id)
  end

  test "keeps undismissed recipients regardless of age" do
    unread = create_recipient(title: "Ancient unread", created_ago: 200.days)
    unread.update_columns(created_at: 200.days.ago)

    read = create_recipient(title: "Ancient read", created_ago: 200.days)
    read.update_columns(read_at: 150.days.ago, created_at: 200.days.ago)

    Tenant.current_id = nil
    PurgeDismissedNotificationsJob.perform_now

    assert NotificationRecipient.unscoped_for_system_job.exists?(unread.id)
    assert NotificationRecipient.unscoped_for_system_job.exists?(read.id)
  end

  test "deletes notifications orphaned by the purge" do
    old = create_recipient(title: "Fully purged", dismissed_ago: 91.days)
    notification = old.notification

    Tenant.current_id = nil
    PurgeDismissedNotificationsJob.perform_now

    assert_not Notification.unscoped_for_system_job.exists?(notification.id)
  end

  test "keeps notifications that still have recipients" do
    old = create_recipient(title: "Shared notification", dismissed_ago: 91.days)
    notification = old.notification

    hex = SecureRandom.hex(4)
    other_user = create_user(name: "Other #{hex}", email: "other-#{hex}@example.com")
    @tenant.add_user!(other_user)
    NotificationRecipient.create!(
      notification: notification,
      user: other_user,
      channel: "in_app",
      status: "delivered"
    )

    Tenant.current_id = nil
    PurgeDismissedNotificationsJob.perform_now

    assert Notification.unscoped_for_system_job.exists?(notification.id)
  end

  test "keeps orphaned notifications referenced by a reminder note" do
    old = create_recipient(title: "Reminder", dismissed_ago: 91.days)
    notification = old.notification

    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Remind me", text: "body")
    note.update_columns(reminder_notification_id: notification.id)

    Tenant.current_id = nil
    PurgeDismissedNotificationsJob.perform_now

    assert_not NotificationRecipient.unscoped_for_system_job.exists?(old.id),
               "the dismissed recipient should still be purged"
    assert Notification.unscoped_for_system_job.exists?(notification.id),
           "the notification must survive while a note references it"
  end

  test "keeps freshly created notifications without recipients" do
    notification = Notification.create!(
      tenant: @tenant,
      notification_type: "mention",
      title: "Mid-creation"
    )

    Tenant.current_id = nil
    PurgeDismissedNotificationsJob.perform_now

    assert Notification.unscoped_for_system_job.exists?(notification.id),
           "notifications mid-delivery (recipients not yet created) must not be swept"
  end
end
