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

  test "read_confirmation event preserves is_creator: true when the user is the note creator" do
    tenant, collective, user = create_tenant_collective_user

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      text: "Test note",
    )

    event = note.note_history_events.find_by!(event_type: "read_confirmation", user: user)
    updates = event.send(:user_item_status_updates)
    assert_equal 1, updates.length
    assert_equal true, updates.first[:is_creator]
    assert_equal true, updates.first[:has_read]

    status = UserItemStatus.find_by!(tenant_id: tenant.id, user_id: user.id, item_type: "Note", item_id: note.id)
    assert status.is_creator, "creator's is_creator flag must survive the read_confirmation upsert"
    assert status.has_read
  end

  test "read_confirmation event sets is_creator: false when the user is not the note creator" do
    tenant, collective, creator = create_tenant_collective_user
    other_user = create_user(name: "Other User")
    tenant.add_user!(other_user)
    collective.add_user!(other_user)

    note = Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: creator,
      updated_by: creator,
      text: "Test note",
    )

    event = note.confirm_read!(other_user)
    updates = event.send(:user_item_status_updates)
    assert_equal 1, updates.length
    assert_equal false, updates.first[:is_creator]
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
