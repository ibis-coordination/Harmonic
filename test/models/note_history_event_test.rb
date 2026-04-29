require "test_helper"

class NoteHistoryEventTest < ActiveSupport::TestCase
  test "reminder event type is valid" do
    tenant, collective, user = create_tenant_collective_user

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
    )

    event = NoteHistoryEvent.create!(
      note: note,
      user: user,
      event_type: "reminder",
      happened_at: Time.current,
    )

    assert event.persisted?
    assert_equal "reminder", event.event_type
    assert_equal "reminder fired", event.description
  end

  test "reminder_acknowledged event type is valid" do
    tenant, collective, user = create_tenant_collective_user

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
    )

    event = NoteHistoryEvent.create!(
      note: note,
      user: user,
      event_type: "reminder_acknowledged",
      happened_at: Time.current,
    )

    assert event.persisted?
    assert_equal "reminder_acknowledged", event.event_type
    assert_equal "acknowledged this reminder", event.description
  end

  test "reminder_acknowledged event updates user item status" do
    tenant, collective, user = create_tenant_collective_user

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
    )

    event = NoteHistoryEvent.create!(
      note: note,
      user: user,
      event_type: "reminder_acknowledged",
      happened_at: Time.current,
    )

    updates = event.send(:user_item_status_updates)
    assert_equal 1, updates.length
    assert_equal true, updates.first[:has_read]
  end

  test "reminder_acknowledged event does not trigger search reindex" do
    tenant, collective, user = create_tenant_collective_user

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Reminder note",
      subtype: "reminder",
    )

    event = NoteHistoryEvent.create!(
      note: note,
      user: user,
      event_type: "reminder_acknowledged",
      happened_at: Time.current,
    )

    # search_index_items should be empty for acknowledgment events
    assert_equal [], event.send(:search_index_items)
  end

  test "read_confirmation event triggers search reindex" do
    tenant, collective, user = create_tenant_collective_user

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Test note",
    )

    event = NoteHistoryEvent.create!(
      note: note,
      user: user,
      event_type: "read_confirmation",
      happened_at: Time.current,
    )

    assert_equal [note], event.send(:search_index_items)
  end

  test "invalid event type is rejected" do
    tenant, collective, user = create_tenant_collective_user

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Test note",
    )

    event = NoteHistoryEvent.new(
      note: note,
      user: user,
      event_type: "invalid_type",
      happened_at: Time.current,
    )

    assert_not event.valid?
  end
end
