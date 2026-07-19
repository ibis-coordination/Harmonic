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
      text: "Hello @mentioned, check this out!"
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

  test "handle_note_event notifies the actor when @cadence is mentioned but cadence is not enabled in the collective" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    user.tenant_user.update!(handle: "alice")
    assert_nil collective.persona_user("cadence"), "precondition: cadence not enabled"

    create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Hey @cadence, can you help with this?"
    )

    hint = Notification.where(notification_type: "persona_unavailable").last
    assert_not_nil hint, "Expected a persona_unavailable hint notification for the actor"
    recipient = hint.notification_recipients.first
    assert_equal user.id, recipient&.user_id
    assert_includes hint.title, "@cadence"
    assert_equal "#{collective.path}/settings", hint.url
  end

  test "handle_note_event hints on @trio only when NO persona is enabled" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    user.tenant_user.update!(handle: "alice")

    create_note(
      tenant: tenant, collective: collective, created_by: user,
      text: "Hey @trio, anyone home?"
    )

    hint = Notification.where(notification_type: "persona_unavailable").last
    assert_not_nil hint, "with no personas enabled, @trio should hint"
    assert_includes hint.title, "@trio"

    # With any persona active, @trio reached someone — no hint.
    melody = User.create!(
      email: "melody_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Melody", user_type: "ai_agent", system_role: "melody", parent_id: nil
    )
    tenant.add_user!(melody, handle: "melody-#{SecureRandom.hex(4)}")
    collective.add_user!(melody)
    collective.collective_members.find_by!(user_id: melody.id).add_roles!(["melody", "trio"])
    collective.clear_persona_user_cache!
    before = Notification.where(notification_type: "persona_unavailable").count

    create_note(
      tenant: tenant, collective: collective, created_by: user,
      text: "Hey @trio, second try"
    )

    assert_equal before, Notification.where(notification_type: "persona_unavailable").count,
      "no hint when at least one persona holds the ensemble role"
  end

  test "handle_note_event sends a workspace-flavored persona_unavailable hint in a private workspace" do
    tenant, _collective, user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)
    workspace = user.private_workspace
    assert workspace.present?, "precondition: user has a private workspace"
    assert_nil workspace.persona_user("cadence"), "precondition: cadence not enabled in workspace"

    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: workspace.handle)

    create_note(
      tenant: tenant,
      collective: workspace,
      created_by: user,
      text: "Hey @cadence, help me organize this."
    )

    hint = Notification.where(notification_type: "persona_unavailable").last
    assert_not_nil hint, "Expected a persona_unavailable hint in workspace"
    assert_equal "/settings", hint.url
    assert_includes hint.body, "your workspace"
  end

  test "handle_note_event does NOT send a persona_unavailable hint when the persona is enabled" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    user.tenant_user.update!(handle: "alice")

    cadence = User.create!(
      email: "cadence_#{SecureRandom.hex(4)}@system.harmonic.local",
      name: "Cadence", user_type: "ai_agent", system_role: "cadence", parent_id: nil
    )
    tenant.add_user!(cadence, handle: "cadence-#{SecureRandom.hex(4)}")
    collective.add_user!(cadence)
    collective.collective_members.find_by!(user_id: cadence.id).add_roles!(["cadence", "trio"])
    collective.clear_persona_user_cache!

    create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Hey @cadence, can you help?"
    )

    hint = Notification.where(notification_type: "persona_unavailable").last
    assert_nil hint, "No hint should be sent when the persona is enabled"
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
      text: "Hello @selfmention!"
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
      text: "Hello world, no mentions here!"
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
      text: "Hey @testuser!"
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
      actor: user
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
      created_by: user
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
      subject: commitment
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
      created_by: user
    )

    initial_count = Notification.count

    # Simulate owner joining their own commitment
    event = Event.create!(
      tenant: tenant,
      collective: collective,
      event_type: "commitment.joined",
      actor: user,
      subject: commitment
    )

    NotificationDispatcher.dispatch(event)

    # No notification should be created
    assert_equal initial_count, Notification.count
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
      actor: user
    )

    # Call notify_user directly
    NotificationDispatcher.notify_user(
      event: event,
      recipient: user,
      notification_type: "comment",
      title: "Test comment"
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
      text: "Hello @emailuser, check this out!"
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
      text: "Hello @noemailuser, check this out!"
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
      text: "Original note content"
    )

    Notification.count

    # Create a reply to the note
    reply = create_note(
      tenant: tenant,
      collective: collective,
      created_by: replier,
      text: "This is a reply!",
      subtype: "comment",
      commentable: original_note
    )

    # Get the created event for the reply
    event = Event.where(event_type: "comment.created", subject: reply).last

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
      text: "My note"
    )

    initial_notification_count = Notification.count

    # Create a reply to their own note
    create_note(
      tenant: tenant,
      collective: collective,
      created_by: user,
      text: "Replying to myself",
      subtype: "comment",
      commentable: original_note
    )

    # No notification should be created for self-reply
    Notification.where(notification_type: "comment")
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
      created_by: decision_owner
    )

    # Create a comment on the decision
    comment = create_note(
      tenant: tenant,
      collective: collective,
      created_by: commenter,
      text: "Great decision!",
      subtype: "comment",
      commentable: decision
    )

    # Get the created event for the comment
    event = Event.where(event_type: "comment.created", subject: comment).last

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

  test "reply notification url highlights the reply, not the comment being replied to" do
    tenant, collective, author = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    replier = create_user(email: "nested-replier@example.com", name: "Nested Replier")
    tenant.add_user!(replier)
    collective.add_user!(replier)

    # author posts a note, then a first comment on it
    note = create_note(tenant: tenant, collective: collective, created_by: author, text: "Root note")
    first_comment = create_note(
      tenant: tenant,
      collective: collective,
      created_by: author,
      text: "First comment",
      subtype: "comment",
      commentable: note
    )

    # replier replies to the first comment
    reply = create_note(
      tenant: tenant,
      collective: collective,
      created_by: replier,
      text: "A reply to the first comment",
      subtype: "comment",
      commentable: first_comment
    )

    event = Event.where(event_type: "comment.created", subject: reply).last
    notification = Notification.where(event: event, notification_type: "comment").last
    assert_not_nil notification, "Expected a reply notification for the first comment's author"

    # The link must land on the reply itself, not the comment being replied to.
    assert_equal reply.display_path, notification.url
    assert_includes notification.url, "comment_id=#{reply.truncated_id}"
    assert_not_includes notification.url, "comment_id=#{first_comment.truncated_id}"
  end

  # NOTE: AI agent task triggering tests have been moved to AutomationDispatcherTest
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
    assert_no_match(/#{Regexp.escape(owner.display_name)}/, notification.title)
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

  test "a mention inside a comment notifies the mentioned user" do
    tenant, collective, user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    mentioned_user = create_user(email: "replyfan@example.com", name: "Reply Fan")
    tenant.add_user!(mentioned_user)
    collective.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "replyfan")

    note = create_note(tenant: tenant, collective: collective, created_by: user)
    comment = note.add_comment(text: "cc @replyfan", created_by: user)

    event = Event.where(subject: comment).last
    notification = Notification.where(event: event, notification_type: "mention").last
    assert_not_nil notification, "Expected a mention notification from the comment"
    assert_equal [mentioned_user.id], notification.notification_recipients.map(&:user_id).uniq
  end

  test "a reply that also mentions the parent author sends one notification, not two" do
    tenant, collective, owner = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    owner.tenant_user.update!(handle: "alice")

    replier = create_user(email: "replier-#{SecureRandom.hex(4)}@example.com", name: "Replier")
    tenant.add_user!(replier)
    collective.add_user!(replier)

    note = create_note(tenant: tenant, collective: collective, created_by: owner)
    comment = note.add_comment(text: "@alice great point!", created_by: replier)

    event = Event.where(subject: comment).last
    # distinct: a notification has one recipient row per channel; count
    # notifications, not channel rows
    owner_notifications = Notification.where(event: event)
      .joins(:notification_recipients)
      .where(notification_recipients: { user_id: owner.id })
      .distinct.to_a

    assert_equal 1, owner_notifications.size,
      "A reply mentioning the parent author should produce exactly one combined notification, not a reply + a mention"
    notification = owner_notifications.first
    assert_equal "mention", notification.notification_type
    assert_match(/mentioned you in their reply to your note/, notification.title)
    # Channel union: mention's default (in_app + email) ∪ comment's default
    # (in_app) — each channel delivers exactly once
    channels = notification.notification_recipients.where(user_id: owner.id).pluck(:channel)
    assert_equal ["email", "in_app"], channels.sort
  end

  test "the combined reply-mention notification honors the channel union when mention is disabled" do
    tenant, collective, owner = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    owner.tenant_user.update!(handle: "alice")
    # Mention notifications fully off; comment keeps its default (in_app).
    # The combined notification should still arrive, via comment's channel.
    tu = owner.tenant_user
    tu.update!(settings: (tu.settings || {}).merge(
      "notification_preferences" => { "mention" => { "in_app" => false, "email" => false, "web_push" => false } },
    ))

    replier = create_user(email: "replier-#{SecureRandom.hex(4)}@example.com", name: "Replier")
    tenant.add_user!(replier)
    collective.add_user!(replier)

    note = create_note(tenant: tenant, collective: collective, created_by: owner)
    comment = note.add_comment(text: "@alice great point!", created_by: replier)

    event = Event.where(subject: comment).last
    owner_notifications = Notification.where(event: event)
      .joins(:notification_recipients)
      .where(notification_recipients: { user_id: owner.id })
      .distinct.to_a

    assert_equal 1, owner_notifications.size
    channels = owner_notifications.first.notification_recipients.where(user_id: owner.id).pluck(:channel)
    assert_equal ["in_app"], channels
  end

  test "a reply mentioning a third party still notifies owner and mentioned user separately" do
    tenant, collective, owner = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    replier = create_user(email: "replier-#{SecureRandom.hex(4)}@example.com", name: "Replier")
    tenant.add_user!(replier)
    collective.add_user!(replier)

    third_party = create_user(email: "third-#{SecureRandom.hex(4)}@example.com", name: "Third Party")
    tenant.add_user!(third_party, handle: "carol")
    collective.add_user!(third_party)

    note = create_note(tenant: tenant, collective: collective, created_by: owner)
    comment = note.add_comment(text: "@carol should see this", created_by: replier)

    event = Event.where(subject: comment).last

    # distinct: a notification has one recipient row per channel; count
    # notifications, not channel rows
    owner_types = Notification.where(event: event)
      .joins(:notification_recipients)
      .where(notification_recipients: { user_id: owner.id })
      .distinct.map(&:notification_type)
    third_party_types = Notification.where(event: event)
      .joins(:notification_recipients)
      .where(notification_recipients: { user_id: third_party.id })
      .distinct.map(&:notification_type)

    assert_equal ["comment"], owner_types
    assert_equal ["mention"], third_party_types
  end

  # ---- commitment join / critical mass notifications ----

  def setup_commitment_with_joiner(critical_mass:)
    tenant, collective, owner = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    joiner = create_user(email: "joiner-#{SecureRandom.hex(4)}@example.com", name: "Joiner")
    tenant.add_user!(joiner)
    collective.add_user!(joiner)

    commitment = Commitment.create!(
      tenant: tenant, collective: collective, created_by: owner,
      title: "Join me", description: "Test commitment",
      critical_mass: critical_mass, deadline: 1.week.from_now
    )

    [commitment, owner, joiner]
  end

  def join!(commitment, user)
    participant = CommitmentParticipantManager.new(commitment: commitment, user: user).find_or_create_participant
    participant.committed = true
    participant.save!
  end

  test "a join notifies the commitment creator" do
    commitment, owner, joiner = setup_commitment_with_joiner(critical_mass: 2)

    join!(commitment, joiner)

    event = Event.where(event_type: "commitment.joined", subject: commitment).last
    notification = Notification.where(event: event).last
    assert_not_nil notification, "Expected a notification for the commitment creator"
    assert_equal "participation", notification.notification_type
    assert_equal [owner.id], notification.notification_recipients.map(&:user_id)
  end

  test "the creator joining their own commitment does not notify them" do
    commitment, owner, _joiner = setup_commitment_with_joiner(critical_mass: 2)

    join!(commitment, owner)

    event = Event.where(event_type: "commitment.joined", subject: commitment).last
    assert_not_nil event
    assert_nil Notification.where(event: event).last
  end

  test "reaching critical mass notifies participants other than the crossing joiner" do
    commitment, owner, joiner = setup_commitment_with_joiner(critical_mass: 2)
    join!(commitment, owner)
    join!(commitment, joiner)

    event = Event.where(event_type: "commitment.critical_mass", subject: commitment).last
    notification = Notification.where(event: event).last
    assert_not_nil notification, "Expected a critical mass notification"
    assert_equal "participation", notification.notification_type
    assert_includes notification.title, "Critical mass"
    assert_equal [owner.id], notification.notification_recipients.map(&:user_id)
  end

  # ---- decision vote notifications ----

  def setup_decision_with_voter
    tenant, collective, owner = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    voter = create_user(email: "voter-#{SecureRandom.hex(4)}@example.com", name: "Voter Vince")
    tenant.add_user!(voter)
    collective.add_user!(voter)

    decision = create_decision(tenant: tenant, collective: collective, created_by: owner)
    option = create_option(decision: decision, created_by: owner, title: "Option A")

    [decision, option, owner, voter]
  end

  def cast_vote!(decision, option, user, preferred: 0)
    participant = DecisionParticipantManager.new(decision: decision, user: user).find_or_create_participant
    vote = Vote.new(
      tenant: decision.tenant, collective: decision.collective, decision: decision,
      option: option, decision_participant: participant, accepted: 1, preferred: preferred
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: user)
    vote
  end

  def vote_notifications_for(decision)
    Notification
      .joins(:event)
      .where(notification_type: "participation", url: decision.display_path)
      .where(events: { event_type: "vote.created" })
  end

  test "a vote notifies the decision creator and attributes the voter" do
    decision, option, owner, voter = setup_decision_with_voter

    cast_vote!(decision, option, voter)

    event = Event.where(event_type: "vote.created").last
    assert_equal voter.id, event.actor_id, "vote.created should be attributed to the voter"

    notification = vote_notifications_for(decision).last
    assert_not_nil notification, "Expected a vote notification for the decision creator"
    assert_includes notification.title, "Voter Vince"
    assert_equal [owner.id], notification.notification_recipients.map(&:user_id)
  end

  test "voting on your own decision creates no notification" do
    decision, option, owner, _voter = setup_decision_with_voter

    cast_vote!(decision, option, owner)

    assert_nil vote_notifications_for(decision).last
  end

  test "a second vote while the first notification is unread does not notify again" do
    decision, option_a, owner, voter = setup_decision_with_voter
    option_b = create_option(decision: decision, created_by: owner, title: "Option B")

    cast_vote!(decision, option_a, voter)
    cast_vote!(decision, option_b, voter)

    assert_equal 1, vote_notifications_for(decision).count
    assert_equal [owner.id], vote_notifications_for(decision).last.notification_recipients.map(&:user_id)
  end

  test "a new vote after the notification is read notifies again" do
    decision, option_a, owner, voter = setup_decision_with_voter
    option_b = create_option(decision: decision, created_by: owner, title: "Option B")

    cast_vote!(decision, option_a, voter)
    vote_notifications_for(decision).last.notification_recipients.each(&:mark_read!)

    cast_vote!(decision, option_b, voter)

    assert_equal 2, vote_notifications_for(decision).count
  end

  # ---- decision resolution notifications ----

  test "decision.deadline_reached notifies participants other than the actor" do
    decision, option, owner, voter = setup_decision_with_voter
    cast_vote!(decision, option, voter)

    EventService.record!(
      event_type: "decision.deadline_reached",
      actor: owner,
      subject: decision,
      metadata: {}
    )

    event = Event.where(event_type: "decision.deadline_reached", subject: decision).last
    notification = Notification.where(event: event).last
    assert_not_nil notification, "Expected a resolution notification for participants"
    assert_equal "participation", notification.notification_type
    assert_includes notification.title, "resolved"
    assert_equal [voter.id], notification.notification_recipients.map(&:user_id)
  end

  test "commitment.deadline_reached creates no notification" do
    commitment, owner, _joiner = setup_commitment_with_joiner(critical_mass: 2)

    EventService.record!(
      event_type: "commitment.deadline_reached",
      actor: owner,
      subject: commitment,
      metadata: {}
    )

    event = Event.where(event_type: "commitment.deadline_reached", subject: commitment).last
    assert_nil Notification.where(event: event).last
  end

  # Role-change notifications (issue #340)

  test "handle_role_granted_event notifies the member and names the granter" do
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)

    member_user = create_user(email: "newrep@example.com", name: "New Rep")
    tenant.add_user!(member_user)
    collective.add_user!(member_user)
    membership = CollectiveMember.find_by(collective: collective, user: member_user)

    event = EventService.record!(
      event_type: "collective_member.role_granted",
      actor: admin,
      subject: membership,
      metadata: { "role" => "representative" },
      collective_id: collective.id
    )

    notification = Notification.where(event: event).last
    assert_not_nil notification, "Expected a role_change notification"
    assert_equal "role_change", notification.notification_type
    assert_includes notification.title, "a representative"
    assert_includes notification.title, admin.display_name
    assert_equal member_user, notification.notification_recipients.first.user
  end

  test "handle_role_granted_event does not notify on a self-grant" do
    tenant, collective, admin = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: tenant.subdomain, handle: collective.handle)
    membership = CollectiveMember.find_by(collective: collective, user: admin)

    assert_no_difference -> { Notification.count } do
      EventService.record!(
        event_type: "collective_member.role_granted",
        actor: admin,
        subject: membership,
        metadata: { "role" => "admin" },
        collective_id: collective.id
      )
    end
  end
end
