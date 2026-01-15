require "test_helper"

class TrackedTest < ActiveSupport::TestCase
  test "creating a note creates a note.created event" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    assert_difference "Event.count", 1 do
      create_note(tenant: tenant, superagent: superagent, created_by: user, text: "Test note")
    end

    event = Event.last
    assert_equal "note.created", event.event_type
    assert_equal user, event.actor
    assert_equal "Note", event.subject_type
  end

  test "updating a note creates a note.updated event" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    note = create_note(tenant: tenant, superagent: superagent, created_by: user, text: "Original text")

    assert_difference "Event.count", 1 do
      note.update!(text: "Updated text")
    end

    event = Event.where(event_type: "note.updated").last
    assert_not_nil event, "Expected a note.updated event to be created"
    assert_equal note, event.subject
    assert event.metadata["changes"].key?("text")
  end

  test "updating only updated_at does not create an event" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    note = create_note(tenant: tenant, superagent: superagent, created_by: user, text: "Test")

    assert_no_difference "Event.count" do
      note.update_column(:updated_at, Time.current)
    end
  end

  test "deleting a note creates a note.deleted event" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    note = create_note(tenant: tenant, superagent: superagent, created_by: user, text: "Test note")
    note_id = note.id

    assert_difference "Event.count", 1 do
      note.destroy!
    end

    event = Event.where(event_type: "note.deleted").last
    assert_not_nil event, "Expected a note.deleted event to be created"
    assert_equal "Note", event.subject_type
    assert_equal note_id, event.subject_id
  end

  test "creating a decision creates a decision.created event" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    assert_difference "Event.count", 1 do
      create_decision(tenant: tenant, superagent: superagent, created_by: user)
    end

    event = Event.last
    assert_equal "decision.created", event.event_type
    assert_equal "Decision", event.subject_type
  end

  test "creating a commitment creates a commitment.created event" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    assert_difference "Event.count", 1 do
      create_commitment(tenant: tenant, superagent: superagent, created_by: user)
    end

    event = Event.last
    assert_equal "commitment.created", event.event_type
    assert_equal "Commitment", event.subject_type
  end

  test "event metadata includes truncated_id and text" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    note = create_note(tenant: tenant, superagent: superagent, created_by: user, text: "Hello world")

    event = Event.last
    assert_equal note.truncated_id, event.metadata["truncated_id"]
    assert_equal "Hello world", event.metadata["text"]
  end
end
