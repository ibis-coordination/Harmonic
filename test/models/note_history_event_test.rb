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
