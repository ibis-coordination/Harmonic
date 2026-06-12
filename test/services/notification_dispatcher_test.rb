require "test_helper"

class NotificationDispatcherTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "handle_note_event creates notifications for mentioned users" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create another user to mention
    mentioned_user = create_user(email: "mentioned@example.com", name: "Mentioned User")
    tenant.add_user!(mentioned_user)
    collective.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "mentioned")

    # Create a note with mention
    note = create_note(
      tenant: tenant,
      collective: collective,
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

  test "handle_note_event notifies the actor when @trio is mentioned but trio is not enabled in the collective" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    user.tenant_user.update!(handle: "alice")
    assert_nil collective.trio_user, "precondition: trio not enabled"

    create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Hey @trio, can you help with this?",
    )

    hint = Notification.where(notification_type: "trio_unavailable").last
    assert_not_nil hint, "Expected a trio_unavailable hint notification for the actor"
    recipient = hint.notification_recipients.first
    assert_equal user.id, recipient&.user_id
    assert_includes hint.title, "Trio"
    assert_equal "#{collective.path}/settings", hint.url
  end

  test "handle_note_event sends a workspace-flavored trio_unavailable hint in a private workspace" do
    tenant, _collective, user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    workspace = user.private_workspace
    assert workspace.present?, "precondition: user has a private workspace"
    assert_nil workspace.trio_user, "precondition: trio not enabled in workspace"

    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: workspace.handle)

    create_note(
      tenant: tenant,
      collective: workspace,
      created_by: user,
      text: "Hey @trio, help me organize this.",
    )

    hint = Notification.where(notification_type: "trio_unavailable").last
    assert_not_nil hint, "Expected a trio_unavailable hint in workspace"
    assert_equal "/settings", hint.url
    assert_includes hint.body, "your workspace"
  end

  test "handle_note_event does NOT send a trio_unavailable hint when trio is enabled" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    user.tenant_user.update!(handle: "alice")

    trio = User.create!(
      email: "trio_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Trio", user_type: "ai_agent", system_role: "trio", parent_id: nil,
    )
    tenant.add_user!(trio, handle: "trio-#{SecureRandom.hex(4)}")
    collective.add_user!(trio)
    collective.update!(trio_user: trio)

    create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Hey @trio, can you help?",
    )

    hint = Notification.where(notification_type: "trio_unavailable").last
    assert_nil hint, "No hint should be sent when trio is enabled"
  end

  test "handle_note_event does not notify the actor" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Set handle for the user
    user.tenant_user.update!(handle: "selfmention")

    initial_count = Notification.count

    # Create a note where user mentions themselves
    create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Hello @selfmention!",
    )

    # No notification should be created for self-mention
    assert_equal initial_count, Notification.count
  end

  test "handle_note_event handles note with no mentions" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    initial_count = Notification.count

    create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Hello world, no mentions here!",
    )

    # No notification should be created
    assert_equal initial_count, Notification.count
  end

  test "dispatch routes to correct handler for note events" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    mentioned_user = create_user(email: "test-mentioned@example.com", name: "Test Mentioned User")
    tenant.add_user!(mentioned_user)
    collective.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "testuser")

    note = create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Hey @testuser!",
    )

    event = Event.where(event_type: "note.created", subject: note).last
    notification = Notification.where(event: event).last

    assert_not_nil notification
    assert_equal "mention", notification.notification_type
  end

  test "dispatch handles unrecognized event types gracefully" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
      event_type: "unknown.event",
      actor: user,
    )

    # Should not raise an error
    assert_nothing_raised do
      NotificationDispatcher.dispatch(event)
    end
  end

  test "handle_commitment_join_event notifies commitment owner" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    commitment = create_commitment(
      tenant: tenant,
      collective: collective,
      created_by: user,
    )

    joining_user = create_user(email: "joiner@example.com", name: "Joiner")
    tenant.add_user!(joining_user)
    collective.add_user!(joining_user)

    # Simulate a commitment.joined event
    event = Event.create!(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    commitment = create_commitment(
      tenant: tenant,
      collective: collective,
      created_by: user,
    )

    initial_count = Notification.count

    # Simulate owner joining their own commitment
    event = Event.create!(
      tenant: tenant,
      collective: collective,
      event_type: "commitment.joined",
      actor: user,
      subject: commitment,
    )

    NotificationDispatcher.dispatch(event)

    # No notification should be created
    assert_equal initial_count, Notification.count
  end

  test "handle_decision_vote_event notifies decision owner" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    decision = create_decision(
      tenant: tenant,
      collective: collective,
      created_by: user,
    )

    voter = create_user(email: "voter@example.com", name: "Voter")
    tenant.add_user!(voter)
    collective.add_user!(voter)

    # Simulate a decision.voted event
    event = Event.create!(
      tenant: tenant,
      collective: collective,
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
    user = User.new(email: "test@example.com", name: "Test", user_type: "human")

    channels = NotificationDispatcher.channels_for_user(user, "mention")
    assert_equal ["in_app"], channels
  end

  test "channels_for_user returns both channels for mention by default" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    channels = NotificationDispatcher.channels_for_user(user, "mention")
    assert_includes channels, "in_app"
    assert_includes channels, "email"
  end

  test "channels_for_user returns only in_app for comment by default" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    channels = NotificationDispatcher.channels_for_user(user, "comment")
    assert_equal ["in_app"], channels
  end

  test "channels_for_user respects user preferences" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Disable email for mentions
    user.tenant_user.set_notification_preference!("mention", "email", false)

    channels = NotificationDispatcher.channels_for_user(user, "mention")
    assert_equal ["in_app"], channels
  end

  test "notify_user creates recipients for correct channels based on preferences" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Enable email for comments (disabled by default)
    user.tenant_user.set_notification_preference!("comment", "email", true)

    event = Event.create!(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create another user to mention (with email enabled by default for mentions)
    mentioned_user = create_user(email: "mentioned-email@example.com", name: "Mentioned Email User")
    tenant.add_user!(mentioned_user)
    collective.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "emailuser")

    # Create a note with mention
    note = create_note(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create another user to mention and disable their email notifications
    mentioned_user = create_user(email: "noemail@example.com", name: "No Email User")
    tenant.add_user!(mentioned_user)
    collective.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "noemailuser")
    mentioned_user.tenant_user.set_notification_preference!("mention", "email", false)

    # Create a note with mention
    note = create_note(
      tenant: tenant,
      collective: collective,
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
    tenant, collective, author = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create another user who will reply
    replier = create_user(email: "replier@example.com", name: "Replier User")
    tenant.add_user!(replier)
    collective.add_user!(replier)

    # Create the original note
    original_note = create_note(
      tenant: tenant,
      collective: collective,
      created_by: author,
      text: "Original note content",
    )

    initial_notification_count = Notification.count

    # Create a reply to the note
    reply = create_note(
      tenant: tenant,
      collective: collective,
      created_by: replier,
      text: "This is a reply!",
      subtype: "comment",
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
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create the original note
    original_note = create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "My note",
    )

    initial_notification_count = Notification.count

    # Create a reply to their own note
    reply = create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Replying to myself",
      subtype: "comment",
      commentable: original_note,
    )

    # No notification should be created for self-reply
    comment_notifications = Notification.where(notification_type: "comment")
    assert_equal initial_notification_count, Notification.count
  end

  test "handle_note_event notifies decision owner when someone comments on decision" do
    tenant, collective, decision_owner = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    # Create another user who will comment
    commenter = create_user(email: "commenter@example.com", name: "Commenter User")
    tenant.add_user!(commenter)
    collective.add_user!(commenter)

    # Create a decision
    decision = create_decision(
      tenant: tenant,
      collective: collective,
      created_by: decision_owner,
    )

    # Create a comment on the decision
    comment = create_note(
      tenant: tenant,
      collective: collective,
      created_by: commenter,
      text: "Great decision!",
      subtype: "comment",
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

  # Note: AI agent task triggering tests have been moved to AutomationDispatcherTest
  # since agent triggering is now handled by the automation system via AutomationDispatcher
  # instead of the hardcoded triggers that were previously in NotificationDispatcher.

  # ---- tune_in notifications ----

  def setup_tune_in_actors
    tenant, collective, actor = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    actor.tenant_user.update!(handle: "alice")

    target = create_user(email: "target-#{SecureRandom.hex(4)}@example.com", name: "Target User")
    tenant.add_user!(target, handle: "bob")
    collective.add_user!(target)

    [tenant, collective, actor, target]
  end

  test "tune-in list add notifies the target with actor profile URL" do
    _tenant, _collective, actor, target = setup_tune_in_actors
    actor_primary = actor.primary_user_list_in!(actor.tenant_users.first.tenant)

    UserListMember.create!(user_list: actor_primary, user: target, added_by: actor)

    notification = Notification.where(notification_type: "tune_in").last
    assert_not_nil notification
    assert_equal "#{actor.display_name} tuned in to you", notification.title
    assert_equal "/u/alice", notification.url
    recipient = notification.notification_recipients.first
    assert_equal target.id, recipient.user_id
  end

  test "self-add to a list creates no notification" do
    _tenant, _collective, actor, _target = setup_tune_in_actors
    list = UserList.create!(creator: actor, owner: actor, name: "My picks", visibility: "public", add_policy: "self_add")

    UserListMember.create!(user_list: list, user: actor, added_by: actor)

    assert_nil Notification.where(notification_type: "tune_in").last
  end

  test "public custom-list add by a non-owner notifies the target with the ADDER's name" do
    tenant, collective, owner, target = setup_tune_in_actors
    adder = create_user(email: "adder-#{SecureRandom.hex(4)}@example.com", name: "Adder Person")
    tenant.add_user!(adder, handle: "adder")
    collective.add_user!(adder)
    list = UserList.create!(creator: owner, owner: owner, name: "Open House",
                            visibility: "public", add_policy: "anyone_add")

    UserListMember.create!(user_list: list, user: target, added_by: adder)

    notification = Notification.where(notification_type: "tune_in").last
    assert_not_nil notification
    assert_includes notification.title, "Adder Person"
    refute_match(/#{Regexp.escape(owner.display_name)}/, notification.title)
    assert_equal list.path, notification.url
  end

  test "public custom-list add notifies the target with list URL" do
    _tenant, _collective, actor, target = setup_tune_in_actors
    list = UserList.create!(creator: actor, owner: actor, name: "Designers", visibility: "public")

    UserListMember.create!(user_list: list, user: target, added_by: actor)

    notification = Notification.where(notification_type: "tune_in").last
    assert_not_nil notification
    assert_includes notification.title, "added you to their list"
    assert_includes notification.title, "Designers"
    assert_equal list.path, notification.url
  end

  test "private custom-list add creates no notification" do
    _tenant, _collective, actor, target = setup_tune_in_actors
    list = UserList.create!(creator: actor, owner: actor, name: "Notes to self", visibility: "private")

    UserListMember.create!(user_list: list, user: target, added_by: actor)

    assert_nil Notification.where(notification_type: "tune_in").last
  end

  test "tune-in across a block boundary does not create a notification" do
    tenant, _collective, actor, target = setup_tune_in_actors
    UserBlock.create!(tenant: tenant, blocker: target, blocked: actor)
    actor_primary = actor.primary_user_list_in!(tenant)

    # Block-cleanup already removed any tune-ins, and the validation will
    # reject the create. We catch the exception and assert no notification.
    assert_raises(ActiveRecord::RecordInvalid) do
      UserListMember.create!(user_list: actor_primary, user: target, added_by: actor)
    end
    assert_nil Notification.where(notification_type: "tune_in").last
  end

  test "rapid tune-out + tune-in does not create a second tune_in notification" do
    _tenant, _collective, actor, target = setup_tune_in_actors
    actor_primary = actor.primary_user_list_in!(actor.tenant_users.first.tenant)
    member = UserListMember.create!(user_list: actor_primary, user: target, added_by: actor)
    assert_equal 1, Notification.where(notification_type: "tune_in").count

    member.destroy!
    assert_no_difference -> { Notification.where(notification_type: "tune_in").count } do
      UserListMember.create!(user_list: actor_primary, user: target, added_by: actor)
    end
  end

  test "re-tune-in after dismissal creates a fresh notification" do
    _tenant, _collective, actor, target = setup_tune_in_actors
    actor_primary = actor.primary_user_list_in!(actor.tenant_users.first.tenant)
    member = UserListMember.create!(user_list: actor_primary, user: target, added_by: actor)
    Notification.where(notification_type: "tune_in").last.notification_recipients
      .update_all(dismissed_at: Time.current, status: "dismissed")
    member.destroy!

    assert_difference -> { Notification.where(notification_type: "tune_in").count }, +1 do
      UserListMember.create!(user_list: actor_primary, user: target, added_by: actor)
    end
  end

  test "re-tune-in after the notification was read creates a fresh notification" do
    _tenant, _collective, actor, target = setup_tune_in_actors
    actor_primary = actor.primary_user_list_in!(actor.tenant_users.first.tenant)
    member = UserListMember.create!(user_list: actor_primary, user: target, added_by: actor)
    Notification.where(notification_type: "tune_in").last.notification_recipients.each(&:mark_read!)
    member.destroy!

    assert_difference -> { Notification.where(notification_type: "tune_in").count }, +1 do
      UserListMember.create!(user_list: actor_primary, user: target, added_by: actor)
    end
  end

  test "user_list_member.deleted event creates no notification" do
    _tenant, _collective, actor, target = setup_tune_in_actors
    actor_primary = actor.primary_user_list_in!(actor.tenant_users.first.tenant)
    member = UserListMember.create!(user_list: actor_primary, user: target, added_by: actor)
    Notification.where(notification_type: "tune_in").destroy_all

    member.destroy!

    assert_nil Notification.where(notification_type: "tune_in").last
  end
end
