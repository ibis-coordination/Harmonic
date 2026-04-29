require "test_helper"

class NoteReminderServiceTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.current_id = @tenant.id
  end

  def create_reminder_note(scheduled_for: 1.day.from_now.in_time_zone("UTC"), delivered: false, cancelled: false)
    notification = ReminderService.create!(
      user: @user,
      title: "Test reminder",
      scheduled_for: scheduled_for,
    )

    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      text: "Reminder content",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: scheduled_for,
    )

    if delivered
      notification.notification_recipients.each(&:mark_delivered!)
    end

    if cancelled
      NoteReminderService.new(note).cancel!
    end

    note
  end

  test "raises for non-reminder notes" do
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      text: "Regular note",
    )

    assert_raises(RuntimeError) do
      NoteReminderService.new(note)
    end
  end

  # State queries

  test "pending? returns true for pending reminders" do
    reminder = NoteReminderService.new(create_reminder_note)
    assert reminder.pending?
    assert_not reminder.delivered?
    assert_not reminder.cancelled?
  end

  test "delivered? returns true after delivery" do
    reminder = NoteReminderService.new(create_reminder_note(delivered: true))
    assert reminder.delivered?
    assert_not reminder.pending?
    assert_not reminder.cancelled?
  end

  test "cancelled? returns true after cancellation" do
    reminder = NoteReminderService.new(create_reminder_note(cancelled: true))
    assert reminder.cancelled?
    assert_not reminder.pending?
    assert_not reminder.delivered?
  end

  test "editable? returns true only for pending reminders" do
    assert NoteReminderService.new(create_reminder_note).editable?
    assert_not NoteReminderService.new(create_reminder_note(delivered: true)).editable?
    assert_not NoteReminderService.new(create_reminder_note(cancelled: true)).editable?
  end

  # Accessors

  test "scheduled_for returns the scheduled time" do
    scheduled_time = 1.day.from_now.in_time_zone("UTC")
    reminder = NoteReminderService.new(create_reminder_note(scheduled_for: scheduled_time))
    assert_in_delta scheduled_time, reminder.scheduled_for, 1.second
  end

  test "recipient returns the first notification recipient" do
    reminder = NoteReminderService.new(create_reminder_note)
    assert_not_nil reminder.recipient
    assert_equal @user.id, reminder.recipient.user_id
  end

  test "recipient returns nil for cancelled reminders" do
    reminder = NoteReminderService.new(create_reminder_note(cancelled: true))
    assert_nil reminder.recipient
  end

  test "acknowledgments returns distinct user count" do
    user2 = create_user(name: "User 2", email: "user2-#{SecureRandom.hex(4)}@example.com")
    note = create_reminder_note(delivered: true)
    reminder = NoteReminderService.new(note)

    reminder.acknowledge!(@user)
    reminder.acknowledge!(user2)

    assert_equal 2, reminder.acknowledgments
  end

  # Actions

  test "cancel! clears notification and preserves scheduled_for" do
    scheduled_time = 1.day.from_now.in_time_zone("UTC")
    note = create_reminder_note(scheduled_for: scheduled_time)
    reminder = NoteReminderService.new(note)

    reminder.cancel!

    assert_nil note.reload.reminder_notification_id
    assert_in_delta scheduled_time, note.reminder_scheduled_for, 1.second
    assert reminder.cancelled?
  end

  test "acknowledge! creates a reminder_acknowledged event" do
    note = create_reminder_note(delivered: true)
    reminder = NoteReminderService.new(note)

    event = reminder.acknowledge!(@user)
    assert event.persisted?
    assert_equal "reminder_acknowledged", event.event_type
    assert_equal @user, event.user
  end

  test "acknowledge! skips duplicate if note not updated" do
    note = create_reminder_note(delivered: true)
    reminder = NoteReminderService.new(note)

    reminder.acknowledge!(@user)
    reminder.acknowledge!(@user)

    assert_equal 1, note.note_history_events.where(event_type: "reminder_acknowledged", user: @user).count
  end

  test "acknowledge! re-acknowledges after note update" do
    note = create_reminder_note(delivered: true)
    reminder = NoteReminderService.new(note)

    reminder.acknowledge!(@user)
    note.update!(text: "Updated", updated_by: @user)
    reminder.acknowledge!(@user)

    assert_equal 2, note.note_history_events.where(event_type: "reminder_acknowledged", user: @user).count
  end
end
