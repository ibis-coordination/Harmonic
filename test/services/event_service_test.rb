require "test_helper"

class EventServiceTest < ActiveSupport::TestCase
  test "record! creates an event" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    note = create_note(tenant: tenant, studio: studio, created_by: user)

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
    assert_equal studio.id, event.studio_id
  end

  test "record! works without actor" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

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
