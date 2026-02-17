require "test_helper"

class EventServiceTest < ActiveSupport::TestCase
  test "record! creates an event" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    note = create_note(tenant: tenant, collective: collective, created_by: user)

    event = EventService.record!(
      event_type: "note.created",
      actor: user,
      subject: note,
      metadata: { truncated_id: note.truncated_id },
    )

    assert event.persisted?
    assert_equal "note.created", event.event_type
    assert_equal user, event.actor
    assert_equal note, event.subject
    assert_equal tenant.id, event.tenant_id
    assert_equal collective.id, event.collective_id
  end

  test "record! works without actor" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = EventService.record!(
      event_type: "system.test",
      actor: nil,
      subject: nil,
      metadata: {},
    )

    assert event.persisted?
    assert_nil event.actor
  end
end
