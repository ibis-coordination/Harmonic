require "test_helper"

class EventTest < ActiveSupport::TestCase
  test "Event.create works" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "note.created",
      actor: user,
      metadata: { test: true },
    )

    assert event.persisted?
    assert_equal "note.created", event.event_type
    assert_equal tenant, event.tenant
    assert_equal studio, event.studio
    assert_equal user, event.actor
    assert_equal({ "test" => true }, event.metadata)
  end

  test "Event can have polymorphic subject" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    note = create_note(tenant: tenant, studio: studio, created_by: user)

    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "note.created",
      actor: user,
      subject: note,
    )

    assert_equal "Note", event.subject_type
    assert_equal note.id, event.subject_id
    assert_equal note, event.subject
  end

  test "event_category returns first part of event_type" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "note.created",
    )

    assert_equal "note", event.event_category
  end

  test "event_action returns last part of event_type" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "note.created",
    )

    assert_equal "created", event.event_action
  end

  test "scopes work correctly" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    # Create events directly (not through Tracked concern) for predictable test
    event1 = Event.create!(tenant: tenant, studio: studio, event_type: "test.created")
    event2 = Event.create!(tenant: tenant, studio: studio, event_type: "test.updated")
    event3 = Event.create!(tenant: tenant, studio: studio, event_type: "other.created")

    assert_includes Event.of_type("test.created").to_a, event1
    assert_includes Event.of_type("test.updated").to_a, event2
    assert_not_includes Event.of_type("test.created").to_a, event3
    assert_not_includes Event.of_type("test.created").to_a, event2
  end
end
