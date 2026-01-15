require "test_helper"

class NotificationDispatcherTest < ActiveSupport::TestCase
  test "handle_note_event creates notifications for mentioned users" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Create another user to mention
    mentioned_user = create_user(email: "mentioned@example.com", name: "Mentioned User")
    tenant.add_user!(mentioned_user)
    superagent.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "mentioned")

    # Create a note with mention
    note = create_note(
      tenant: tenant,
      superagent: superagent,
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
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Set handle for the user
    user.tenant_user.update!(handle: "selfmention")

    initial_count = Notification.count

    # Create a note where user mentions themselves
    create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
      text: "Hello @selfmention!",
    )

    # No notification should be created for self-mention
    assert_equal initial_count, Notification.count
  end

  test "handle_note_event handles note with no mentions" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    initial_count = Notification.count

    create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
      text: "Hello world, no mentions here!",
    )

    # No notification should be created
    assert_equal initial_count, Notification.count
  end

  test "dispatch routes to correct handler for note events" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    mentioned_user = create_user(email: "test-mentioned@example.com", name: "Test Mentioned User")
    tenant.add_user!(mentioned_user)
    superagent.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "testuser")

    note = create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
      text: "Hey @testuser!",
    )

    event = Event.where(event_type: "note.created", subject: note).last
    notification = Notification.where(event: event).last

    assert_not_nil notification
    assert_equal "mention", notification.notification_type
  end

  test "dispatch handles unrecognized event types gracefully" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "unknown.event",
      actor: user,
    )

    # Should not raise an error
    assert_nothing_raised do
      NotificationDispatcher.dispatch(event)
    end
  end

  test "handle_commitment_join_event notifies commitment owner" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    commitment = create_commitment(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
    )

    joining_user = create_user(email: "joiner@example.com", name: "Joiner")
    tenant.add_user!(joining_user)
    superagent.add_user!(joining_user)

    # Simulate a commitment.joined event
    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
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
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    commitment = create_commitment(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
    )

    initial_count = Notification.count

    # Simulate owner joining their own commitment
    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "commitment.joined",
      actor: user,
      subject: commitment,
    )

    NotificationDispatcher.dispatch(event)

    # No notification should be created
    assert_equal initial_count, Notification.count
  end

  test "handle_decision_vote_event notifies decision owner" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    decision = create_decision(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
    )

    voter = create_user(email: "voter@example.com", name: "Voter")
    tenant.add_user!(voter)
    superagent.add_user!(voter)

    # Simulate a decision.voted event
    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
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

  # Preference-based channel selection tests

  test "channels_for_user returns default in_app when no tenant_user" do
    user = User.new(email: "test@example.com", name: "Test", user_type: "person")

    channels = NotificationDispatcher.channels_for_user(user, "mention")
    assert_equal ["in_app"], channels
  end

  test "channels_for_user returns both channels for mention by default" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    channels = NotificationDispatcher.channels_for_user(user, "mention")
    assert_includes channels, "in_app"
    assert_includes channels, "email"
  end

  test "channels_for_user returns only in_app for comment by default" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    channels = NotificationDispatcher.channels_for_user(user, "comment")
    assert_equal ["in_app"], channels
  end

  test "channels_for_user respects user preferences" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Disable email for mentions
    user.tenant_user.set_notification_preference!("mention", "email", false)

    channels = NotificationDispatcher.channels_for_user(user, "mention")
    assert_equal ["in_app"], channels
  end

  test "notify_user creates recipients for correct channels based on preferences" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Enable email for comments (disabled by default)
    user.tenant_user.set_notification_preference!("comment", "email", true)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "comment.created",
      actor: user,
    )

    # Call notify_user directly
    NotificationDispatcher.notify_user(
      event: event,
      recipient: user,
      notification_type: "comment",
      title: "Test comment",
    )

    notification = Notification.where(event: event).last
    recipients = notification.notification_recipients

    assert_equal 2, recipients.count
    channels = recipients.map(&:channel)
    assert_includes channels, "in_app"
    assert_includes channels, "email"
  end

  test "handle_note_event creates email recipient for mentions when enabled" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Create another user to mention (with email enabled by default for mentions)
    mentioned_user = create_user(email: "mentioned-email@example.com", name: "Mentioned Email User")
    tenant.add_user!(mentioned_user)
    superagent.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "emailuser")

    # Create a note with mention
    note = create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
      text: "Hello @emailuser, check this out!",
    )

    # Get the created event
    event = Event.where(event_type: "note.created", subject: note).last
    notification = Notification.where(event: event).last

    # Should have both in_app and email recipients
    recipients = notification.notification_recipients
    channels = recipients.map(&:channel)
    assert_includes channels, "in_app"
    assert_includes channels, "email"
  end

  test "handle_note_event skips email when user disables it" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Create another user to mention and disable their email notifications
    mentioned_user = create_user(email: "noemail@example.com", name: "No Email User")
    tenant.add_user!(mentioned_user)
    superagent.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "noemailuser")
    mentioned_user.tenant_user.set_notification_preference!("mention", "email", false)

    # Create a note with mention
    note = create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
      text: "Hello @noemailuser, check this out!",
    )

    # Get the created event
    event = Event.where(event_type: "note.created", subject: note).last
    notification = Notification.where(event: event).last

    # Should have only in_app recipient
    recipients = notification.notification_recipients
    assert_equal 1, recipients.count
    assert_equal "in_app", recipients.first.channel
  end

  # Reply notification tests

  test "handle_note_event notifies note owner when someone replies" do
    tenant, superagent, author = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Create another user who will reply
    replier = create_user(email: "replier@example.com", name: "Replier User")
    tenant.add_user!(replier)
    superagent.add_user!(replier)

    # Create the original note
    original_note = create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: author,
      text: "Original note content",
    )

    initial_notification_count = Notification.count

    # Create a reply to the note
    reply = create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: replier,
      text: "This is a reply!",
      commentable: original_note,
    )

    # Get the created event for the reply
    event = Event.where(event_type: "note.created", subject: reply).last

    # Check that a notification was created for the original author
    notification = Notification.where(event: event, notification_type: "comment").last
    assert_not_nil notification, "Expected a notification to be created for the note owner"
    assert_equal "comment", notification.notification_type
    assert_includes notification.title, "replied to your note"

    # Check recipient is the original author
    recipient = notification.notification_recipients.first
    assert_not_nil recipient
    assert_equal author.id, recipient.user_id
  end

  test "handle_note_event does not notify author when they reply to their own note" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Create the original note
    original_note = create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
      text: "My note",
    )

    initial_notification_count = Notification.count

    # Create a reply to their own note
    reply = create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: user,
      text: "Replying to myself",
      commentable: original_note,
    )

    # No notification should be created for self-reply
    comment_notifications = Notification.where(notification_type: "comment")
    assert_equal initial_notification_count, Notification.count
  end

  test "handle_note_event notifies decision owner when someone comments on decision" do
    tenant, superagent, decision_owner = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    # Create another user who will comment
    commenter = create_user(email: "commenter@example.com", name: "Commenter User")
    tenant.add_user!(commenter)
    superagent.add_user!(commenter)

    # Create a decision
    decision = create_decision(
      tenant: tenant,
      superagent: superagent,
      created_by: decision_owner,
    )

    # Create a comment on the decision
    comment = create_note(
      tenant: tenant,
      superagent: superagent,
      created_by: commenter,
      text: "Great decision!",
      commentable: decision,
    )

    # Get the created event for the comment
    event = Event.where(event_type: "note.created", subject: comment).last

    # Check that a notification was created for the decision owner
    notification = Notification.where(event: event, notification_type: "comment").last
    assert_not_nil notification, "Expected a notification to be created for the decision owner"
    assert_equal "comment", notification.notification_type
    assert_includes notification.title, "replied to your decision"

    # Check recipient is the decision owner
    recipient = notification.notification_recipients.first
    assert_not_nil recipient
    assert_equal decision_owner.id, recipient.user_id
  end
end
