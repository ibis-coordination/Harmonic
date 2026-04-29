require "test_helper"

class NoteReaderTest < ActiveSupport::TestCase
  test "acknowledged_reminder? returns false when no acknowledgment exists" do
    tenant, collective, user = create_tenant_collective_user
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    notification.notification_recipients.each(&:mark_delivered!)

    reader = NoteReader.new(note: note, user: user)
    assert_not reader.acknowledged_reminder?
  end

  test "acknowledged_reminder? returns true after acknowledgment" do
    tenant, collective, user = create_tenant_collective_user
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    notification.notification_recipients.each(&:mark_delivered!)
    note.acknowledge_reminder!(user)

    reader = NoteReader.new(note: note, user: user)
    assert reader.acknowledged_reminder?
  end

  test "acknowledged_but_note_updated? returns true when note updated after acknowledgment" do
    tenant, collective, user = create_tenant_collective_user
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    notification.notification_recipients.each(&:mark_delivered!)
    note.acknowledge_reminder!(user)
    note.update!(text: "Updated reminder", updated_by: user)

    reader = NoteReader.new(note: note, user: user)
    assert reader.acknowledged_but_note_updated?
  end

  test "acknowledged_but_note_updated? returns false when note not updated after acknowledgment" do
    tenant, collective, user = create_tenant_collective_user
    Tenant.current_id = tenant.id

    notification = ReminderService.create!(
      user: user,
      title: "Test reminder",
      scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
      reminder_notification_id: notification.id,
      reminder_scheduled_for: 1.day.from_now.in_time_zone("UTC"),
    )

    notification.notification_recipients.each(&:mark_delivered!)
    note.acknowledge_reminder!(user)

    reader = NoteReader.new(note: note, user: user)
    assert_not reader.acknowledged_but_note_updated?
  end
end
