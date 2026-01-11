require "test_helper"

class NotificationDispatcherTest < ActiveSupport::TestCase
  test "handle_note_event creates notifications for mentioned users" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    # Create another user to mention
    mentioned_user = create_user(email: "mentioned@example.com", name: "Mentioned User")
    tenant.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "mentioned")

    # Create a note with mention
    note = create_note(
      tenant: tenant,
      studio: studio,
      created_by: user,
      text: "Hello @mentioned, check this out!",
    )

    # Get the created event
    event = Event.where(event_type: "note.created", subject: note).last

    # Check that notification was created for mentioned user
    notification = Notification.where(event: event).last
    assert_not_nil notification, "Expected a notification to be created"
    assert_equal "mention", notification.notification_type
    assert_includes notification.title, "mentioned you"

    # Check recipient
    recipient = notification.notification_recipients.first
    assert_not_nil recipient
    assert_equal mentioned_user.id, recipient.user_id
  end

  test "handle_note_event does not notify the actor" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    # Set handle for the user
    user.tenant_user.update!(handle: "selfmention")

    initial_count = Notification.count

    # Create a note where user mentions themselves
    create_note(
      tenant: tenant,
      studio: studio,
      created_by: user,
      text: "Hello @selfmention!",
    )

    # No notification should be created for self-mention
    assert_equal initial_count, Notification.count
  end

  test "handle_note_event handles note with no mentions" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    initial_count = Notification.count

    create_note(
      tenant: tenant,
      studio: studio,
      created_by: user,
      text: "Hello world, no mentions here!",
    )

    # No notification should be created
    assert_equal initial_count, Notification.count
  end

  test "dispatch routes to correct handler for note events" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    mentioned_user = create_user(email: "test-mentioned@example.com", name: "Test Mentioned User")
    tenant.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "testuser")

    note = create_note(
      tenant: tenant,
      studio: studio,
      created_by: user,
      text: "Hey @testuser!",
    )

    event = Event.where(event_type: "note.created", subject: note).last
    notification = Notification.where(event: event).last

    assert_not_nil notification
    assert_equal "mention", notification.notification_type
  end

  test "dispatch handles unrecognized event types gracefully" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "unknown.event",
      actor: user,
    )

    # Should not raise an error
    assert_nothing_raised do
      NotificationDispatcher.dispatch(event)
    end
  end

  test "handle_commitment_join_event notifies commitment owner" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    commitment = create_commitment(
      tenant: tenant,
      studio: studio,
      created_by: user,
    )

    joining_user = create_user(email: "joiner@example.com", name: "Joiner")
    tenant.add_user!(joining_user)
    studio.add_user!(joining_user)

    # Simulate a commitment.joined event
    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "commitment.joined",
      actor: joining_user,
      subject: commitment,
    )

    NotificationDispatcher.dispatch(event)

    notification = Notification.where(event: event).last
    assert_not_nil notification
    assert_equal "participation", notification.notification_type
    assert_includes notification.title, "joined your commitment"

    recipient = notification.notification_recipients.first
    assert_equal user.id, recipient.user_id
  end

  test "handle_commitment_join_event does not notify if joiner is owner" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    commitment = create_commitment(
      tenant: tenant,
      studio: studio,
      created_by: user,
    )

    initial_count = Notification.count

    # Simulate owner joining their own commitment
    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "commitment.joined",
      actor: user,
      subject: commitment,
    )

    NotificationDispatcher.dispatch(event)

    # No notification should be created
    assert_equal initial_count, Notification.count
  end

  test "handle_decision_vote_event notifies decision owner" do
    tenant, studio, user = create_tenant_studio_user
    Studio.scope_thread_to_studio(subdomain: tenant.subdomain, handle: studio.handle)

    decision = create_decision(
      tenant: tenant,
      studio: studio,
      created_by: user,
    )

    voter = create_user(email: "voter@example.com", name: "Voter")
    tenant.add_user!(voter)
    studio.add_user!(voter)

    # Simulate a decision.voted event
    event = Event.create!(
      tenant: tenant,
      studio: studio,
      event_type: "decision.voted",
      actor: voter,
      subject: decision,
      metadata: { "vote_type" => "accepted" },
    )

    NotificationDispatcher.dispatch(event)

    notification = Notification.where(event: event).last
    assert_not_nil notification
    assert_equal "participation", notification.notification_type
    assert_includes notification.title, "accepted on your decision"

    recipient = notification.notification_recipients.first
    assert_equal user.id, recipient.user_id
  end
end
