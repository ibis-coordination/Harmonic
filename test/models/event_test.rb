require "test_helper"

class EventTest < ActiveSupport::TestCase
  test "Event.create works" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
      event_type: "note.created",
      actor: user,
      metadata: { test: true },
    )

    assert event.persisted?
    assert_equal "note.created", event.event_type
    assert_equal tenant, event.tenant
    assert_equal collective, event.collective
    assert_equal user, event.actor
    assert_equal({ "test" => true }, event.metadata)
  end

  test "Event can have polymorphic subject" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    note = create_note(tenant: tenant, collective: collective, created_by: user)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
      event_type: "note.created",
      actor: user,
      subject: note,
    )

    assert_equal "Note", event.subject_type
    assert_equal note.id, event.subject_id
    assert_equal note, event.subject
  end

  test "event_category returns first part of event_type" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
      event_type: "note.created",
    )

    assert_equal "note", event.event_category
  end

  test "event_action returns last part of event_type" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
      event_type: "note.created",
    )

    assert_equal "created", event.event_action
  end

  test "scopes work correctly" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create events directly (not through Tracked concern) for predictable test
    event1 = Event.create!(tenant: tenant, collective: collective, event_type: "test.created")
    event2 = Event.create!(tenant: tenant, collective: collective, event_type: "test.updated")
    event3 = Event.create!(tenant: tenant, collective: collective, event_type: "other.created")

    assert_includes Event.of_type("test.created").to_a, event1
    assert_includes Event.of_type("test.updated").to_a, event2
    assert_not_includes Event.of_type("test.created").to_a, event3
    assert_not_includes Event.of_type("test.created").to_a, event2
  end
end
