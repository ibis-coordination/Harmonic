require "test_helper"

class EventTest < ActiveSupport::TestCase
  test "Event.create works" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
      actor: user,
      metadata: { test: true },
    )

    assert event.persisted?
    assert_equal "note.created", event.event_type
    assert_equal tenant, event.tenant
    assert_equal superagent, event.superagent
    assert_equal user, event.actor
    assert_equal({ "test" => true }, event.metadata)
  end

  test "Event can have polymorphic subject" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    note = create_note(tenant: tenant, superagent: superagent, created_by: user)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
      actor: user,
      subject: note,
    )

    assert_equal "Note", event.subject_type
    assert_equal note.id, event.subject_id
    assert_equal note, event.subject
  end

  test "event_category returns first part of event_type" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
    )

    assert_equal "note", event.event_category
  end

  test "event_action returns last part of event_type" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
    )

    assert_equal "created", event.event_action
  end

  test "scopes work correctly" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Create events directly (not through Tracked concern) for predictable test
    event1 = Event.create!(tenant: tenant, superagent: superagent, event_type: "test.created")
    event2 = Event.create!(tenant: tenant, superagent: superagent, event_type: "test.updated")
    event3 = Event.create!(tenant: tenant, superagent: superagent, event_type: "other.created")

    assert_includes Event.of_type("test.created").to_a, event1
    assert_includes Event.of_type("test.updated").to_a, event2
    assert_not_includes Event.of_type("test.created").to_a, event3
    assert_not_includes Event.of_type("test.created").to_a, event2
  end
end
