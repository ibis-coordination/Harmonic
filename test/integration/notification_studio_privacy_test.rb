require "test_helper"

class NotificationStudioPrivacyTest < ActionDispatch::IntegrationTest
  # Tests for studio privacy in the notification system.
  #
  # These tests verify that notifications respect studio membership boundaries:
  # users should only receive notifications about content from studios they
  # are members of.
  #
  # Scenario:
  # - User A is a member of Studio X
  # - User B is NOT a member of Studio X
  # - User A creates content in Studio X and @mentions User B
  #
  # Expected behavior: No notification should be created for User B
  # because they are not a member of Studio X and cannot see its content.
  #
  # Bug #1: NotificationDispatcher.handle_note_event notifies all mentioned users
  # without checking studio membership. The fix should filter out mentioned users
  # who are not members of the studio where the content was created.
  #
  # This bug affects:
  # - Notes with @mentions
  # - Comments on notes with @mentions
  # - Comments on decisions with @mentions
  # - Comments on commitments with @mentions
  #
  # (Comments are implemented as Notes with a commentable_id, so they go through
  # the same handle_note_event code path.)
  #
  # Bug #2: Mentions in decision/commitment/option fields are NOT parsed at all.
  # Members should receive notifications when mentioned in these fields, but
  # currently they don't. The fix should add mention parsing to decision.created,
  # commitment.created, and option.created event handlers, while also checking
  # studio membership to avoid leaking content to non-members.

  def setup
    @tenant = create_tenant(subdomain: "privacy-test", name: "Privacy Test Tenant")

    # User A - member of Studio X
    @user_a = create_user(email: "user_a@example.com", name: "User A")
    @tenant.add_user!(@user_a)
    @user_a.tenant_user.update!(handle: "user_a")

    # User B - NOT a member of Studio X (but is in the same tenant)
    @user_b = create_user(email: "user_b@example.com", name: "User B")
    @tenant.add_user!(@user_b)
    @user_b.tenant_user.update!(handle: "user_b")

    # Create main studio for tenant (required for sign_in_as to work)
    @tenant.create_main_studio!(created_by: @user_a)
    main_studio = @tenant.main_studio
    main_studio.add_user!(@user_a)
    main_studio.add_user!(@user_b)

    # Studio X - only User A is a member (this is the private studio)
    @studio_x = create_superagent(tenant: @tenant, created_by: @user_a, name: "Studio X", handle: "studio-x")
    @studio_x.add_user!(@user_a)
    # Note: User B is intentionally NOT added to studio_x

    host! "#{@tenant.subdomain}.#{ENV["HOSTNAME"]}"
  end

  test "non-member should NOT receive notification when mentioned in private studio" do
    # Set up the studio scope for creating the note
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a note that mentions User B (who is NOT a studio member)
    secret_content = "This is private studio content that @user_b should NOT see!"
    note = create_note(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      title: "Private Note",
      text: secret_content
    )

    # Create the event (this happens when a note is created)
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "note.created",
      actor: @user_a,
      subject: note
    )

    # Dispatch notifications
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User B is NOT a member of Studio X
    refute @studio_x.user_is_member?(@user_b), "Test setup error: User B should NOT be a member of Studio X"

    # User B should NOT receive a notification because they are not a member of Studio X
    notification_for_user_b = NotificationRecipient.unscoped.find_by(user: @user_b)

    assert_nil notification_for_user_b,
      "Non-members should NOT receive notifications about private studio content"
  end

  test "non-member should NOT see private content on notifications page" do
    # Set up the studio scope for creating the note
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a note that mentions User B (who is NOT a studio member)
    secret_content = "CONFIDENTIAL: Secret project details that @user_b must not see!"
    note = create_note(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      title: "Confidential Note",
      text: secret_content
    )

    # Create and dispatch the event
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "note.created",
      actor: @user_a,
      subject: note
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Sign in as User B (who is NOT a member of Studio X)
    sign_in_as(@user_b, tenant: @tenant)

    # User B visits their notifications page
    get "/notifications"
    assert_response :success

    # User B should NOT see any private studio content on their notifications page
    assert_no_match(/CONFIDENTIAL/, response.body,
      "Non-members should NOT see private studio content on their notifications page")
    assert_no_match(/Secret project details/, response.body,
      "Private content should NOT be leaked to non-members")
  end

  test "member should receive notification when mentioned" do
    # This test verifies normal behavior still works - members SHOULD get notifications

    # Add a third user who IS a member of Studio X
    user_c = create_user(email: "user_c@example.com", name: "User C")
    @tenant.add_user!(user_c)
    user_c.tenant_user.update!(handle: "user_c")
    @studio_x.add_user!(user_c)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a note that mentions User C (who IS a studio member)
    note = create_note(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      title: "Team Note",
      text: "Hey @user_c, please review this!"
    )

    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "note.created",
      actor: @user_a,
      subject: note
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User C IS a member
    assert @studio_x.user_is_member?(user_c), "Test setup error: User C should be a member of Studio X"

    # User C SHOULD receive a notification (this is expected behavior)
    notification_for_user_c = NotificationRecipient.unscoped.find_by(user: user_c)
    assert_not_nil notification_for_user_c,
      "Members should receive notifications when mentioned"
  end

  # === Comment Tests (Comments are Notes with commentable_id set) ===

  test "non-member should NOT receive notification when mentioned in comment on decision" do
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a decision in Studio X
    decision = create_decision(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      question: "What should we do?",
      description: "Internal discussion"
    )

    # User A adds a comment that mentions User B (who is NOT a studio member)
    comment = Note.create!(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      updated_by: @user_a,
      text: "SECRET DECISION INFO: Hey @user_b, what do you think about this private matter?",
      commentable: decision
    )

    # Create the event for the comment (comments are notes)
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "note.created",
      actor: @user_a,
      subject: comment
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User B is NOT a member of Studio X
    refute @studio_x.user_is_member?(@user_b), "Test setup error: User B should NOT be a member of Studio X"

    # User B should NOT receive a notification about the comment
    notification_for_user_b = NotificationRecipient.unscoped.find_by(user: @user_b)

    assert_nil notification_for_user_b,
      "Non-members should NOT receive notifications about comments in private studios"
  end

  test "non-member should NOT receive notification when mentioned in comment on commitment" do
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a commitment in Studio X
    commitment = create_commitment(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      title: "Secret Initiative",
      description: "Confidential project"
    )

    # User A adds a comment that mentions User B (who is NOT a studio member)
    comment = Note.create!(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      updated_by: @user_a,
      text: "SECRET COMMITMENT INFO: @user_b should join this confidential initiative!",
      commentable: commitment
    )

    # Create the event for the comment
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "note.created",
      actor: @user_a,
      subject: comment
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User B is NOT a member of Studio X
    refute @studio_x.user_is_member?(@user_b), "Test setup error: User B should NOT be a member of Studio X"

    # User B should NOT receive a notification about the comment
    notification_for_user_b = NotificationRecipient.unscoped.find_by(user: @user_b)

    assert_nil notification_for_user_b,
      "Non-members should NOT receive notifications about comments on commitments in private studios"
  end

  test "non-member should NOT receive notification when mentioned in comment on note" do
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a note in Studio X
    parent_note = create_note(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      title: "Parent Note",
      text: "Some internal discussion"
    )

    # User A adds a comment that mentions User B (who is NOT a studio member)
    comment = Note.create!(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      updated_by: @user_a,
      text: "PRIVATE COMMENT: @user_b, this is confidential information!",
      commentable: parent_note
    )

    # Create the event for the comment
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "note.created",
      actor: @user_a,
      subject: comment
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # User B should NOT receive a notification about the comment
    notification_for_user_b = NotificationRecipient.unscoped.find_by(user: @user_b)

    assert_nil notification_for_user_b,
      "Non-members should NOT receive notifications about comments on notes in private studios"
  end

  # === Decision/Commitment Description Tests ===
  # These tests verify that mentions in decision/commitment descriptions:
  # 1. DO notify members when they are mentioned (currently broken - mentions not parsed)
  # 2. Do NOT notify non-members (privacy guardrail for when parsing is added)
  #
  # Bug: Currently mentions in decision/commitment descriptions are NOT parsed at all,
  # so members don't receive notifications when mentioned. The fix should add mention
  # parsing to handle_decision_created and handle_commitment_created events, while
  # also checking studio membership.

  test "non-member should NOT receive notification when mentioned in decision description" do
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a decision with User B mentioned in the description
    decision = Decision.create!(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      updated_by: @user_a,
      question: "What should we do about the secret project?",
      description: "SECRET DECISION: @user_b should not see this confidential strategy discussion!",
      deadline: 1.week.from_now
    )

    # Create the event for decision creation
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "decision.created",
      actor: @user_a,
      subject: decision
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User B is NOT a member of Studio X
    refute @studio_x.user_is_member?(@user_b), "Test setup error: User B should NOT be a member of Studio X"

    # User B should NOT receive a notification about the decision
    notification_for_user_b = NotificationRecipient.unscoped.find_by(user: @user_b)

    assert_nil notification_for_user_b,
      "Non-members should NOT receive notifications about decisions in private studios"
  end

  test "non-member should NOT receive notification when mentioned in commitment description" do
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a commitment with User B mentioned in the description
    commitment = Commitment.create!(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      updated_by: @user_a,
      title: "Secret Initiative",
      description: "CONFIDENTIAL: @user_b should not see this private commitment details!",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    # Create the event for commitment creation
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "commitment.created",
      actor: @user_a,
      subject: commitment
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User B is NOT a member of Studio X
    refute @studio_x.user_is_member?(@user_b), "Test setup error: User B should NOT be a member of Studio X"

    # User B should NOT receive a notification about the commitment
    notification_for_user_b = NotificationRecipient.unscoped.find_by(user: @user_b)

    assert_nil notification_for_user_b,
      "Non-members should NOT receive notifications about commitments in private studios"
  end

  test "member should receive notification when mentioned in decision description" do
    # Add a third user who IS a member of Studio X
    user_c = create_user(email: "user_c@example.com", name: "User C")
    @tenant.add_user!(user_c)
    user_c.tenant_user.update!(handle: "user_c")
    @studio_x.add_user!(user_c)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a decision with User C mentioned in the description
    decision = Decision.create!(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      updated_by: @user_a,
      question: "What should we do about the project?",
      description: "Hey @user_c, what do you think about this approach?",
      deadline: 1.week.from_now
    )

    # Create the event for decision creation
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "decision.created",
      actor: @user_a,
      subject: decision
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User C IS a member of Studio X
    assert @studio_x.user_is_member?(user_c), "Test setup error: User C should be a member of Studio X"

    # User C SHOULD receive a notification because they are mentioned and are a member
    notification_for_user_c = NotificationRecipient.unscoped.find_by(user: user_c)

    assert_not_nil notification_for_user_c,
      "Members should receive notifications when mentioned in decision descriptions"
  end

  test "member should receive notification when mentioned in commitment description" do
    # Add a third user who IS a member of Studio X
    user_c = create_user(email: "user_c@example.com", name: "User C")
    @tenant.add_user!(user_c)
    user_c.tenant_user.update!(handle: "user_c")
    @studio_x.add_user!(user_c)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a commitment with User C mentioned in the description
    commitment = Commitment.create!(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      updated_by: @user_a,
      title: "Team Initiative",
      description: "Hey @user_c, we need your help with this initiative!",
      critical_mass: 5,
      deadline: 1.week.from_now
    )

    # Create the event for commitment creation
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "commitment.created",
      actor: @user_a,
      subject: commitment
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User C IS a member of Studio X
    assert @studio_x.user_is_member?(user_c), "Test setup error: User C should be a member of Studio X"

    # User C SHOULD receive a notification because they are mentioned and are a member
    notification_for_user_c = NotificationRecipient.unscoped.find_by(user: user_c)

    assert_not_nil notification_for_user_c,
      "Members should receive notifications when mentioned in commitment descriptions"
  end

  # === Option Tests ===
  # Options belong to decisions and have title and description fields.
  # Mentions in these fields should notify members but not non-members.

  test "non-member should NOT receive notification when mentioned in option title" do
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a decision in Studio X
    decision = create_decision(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      question: "What approach should we take?"
    )

    # User A creates a decision participant for themselves
    participant_a = DecisionParticipantManager.new(decision: decision, user: @user_a).find_or_create_participant

    # User A adds an option that mentions User B in the title
    option = Option.create!(
      tenant: @tenant,
      superagent: @studio_x,
      decision: decision,
      decision_participant: participant_a,
      title: "SECRET OPTION: Ask @user_b for their input on this confidential matter"
    )

    # Create the event for option creation
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "option.created",
      actor: @user_a,
      subject: option
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User B is NOT a member of Studio X
    refute @studio_x.user_is_member?(@user_b), "Test setup error: User B should NOT be a member of Studio X"

    # User B should NOT receive a notification about the option
    notification_for_user_b = NotificationRecipient.unscoped.find_by(user: @user_b)

    assert_nil notification_for_user_b,
      "Non-members should NOT receive notifications about options in private studios"
  end

  test "non-member should NOT receive notification when mentioned in option description" do
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a decision in Studio X
    decision = create_decision(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      question: "What approach should we take?"
    )

    # User A creates a decision participant for themselves
    participant_a = DecisionParticipantManager.new(decision: decision, user: @user_a).find_or_create_participant

    # User A adds an option that mentions User B in the description
    option = Option.create!(
      tenant: @tenant,
      superagent: @studio_x,
      decision: decision,
      decision_participant: participant_a,
      title: "Option A",
      description: "SECRET INFO: @user_b has expertise in this area but shouldn't see this"
    )

    # Create the event for option creation
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "option.created",
      actor: @user_a,
      subject: option
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User B is NOT a member of Studio X
    refute @studio_x.user_is_member?(@user_b), "Test setup error: User B should NOT be a member of Studio X"

    # User B should NOT receive a notification about the option
    notification_for_user_b = NotificationRecipient.unscoped.find_by(user: @user_b)

    assert_nil notification_for_user_b,
      "Non-members should NOT receive notifications about option descriptions in private studios"
  end

  test "member should receive notification when mentioned in option title" do
    # Add a third user who IS a member of Studio X
    user_c = create_user(email: "user_c@example.com", name: "User C")
    @tenant.add_user!(user_c)
    user_c.tenant_user.update!(handle: "user_c")
    @studio_x.add_user!(user_c)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a decision in Studio X
    decision = create_decision(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      question: "What approach should we take?"
    )

    # User A creates a decision participant for themselves
    participant_a = DecisionParticipantManager.new(decision: decision, user: @user_a).find_or_create_participant

    # User A adds an option that mentions User C in the title
    option = Option.create!(
      tenant: @tenant,
      superagent: @studio_x,
      decision: decision,
      decision_participant: participant_a,
      title: "Have @user_c lead this initiative"
    )

    # Create the event for option creation
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "option.created",
      actor: @user_a,
      subject: option
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User C IS a member of Studio X
    assert @studio_x.user_is_member?(user_c), "Test setup error: User C should be a member of Studio X"

    # User C SHOULD receive a notification because they are mentioned and are a member
    notification_for_user_c = NotificationRecipient.unscoped.find_by(user: user_c)

    assert_not_nil notification_for_user_c,
      "Members should receive notifications when mentioned in option titles"
  end

  test "member should receive notification when mentioned in option description" do
    # Add a third user who IS a member of Studio X
    user_c = create_user(email: "user_c@example.com", name: "User C")
    @tenant.add_user!(user_c)
    user_c.tenant_user.update!(handle: "user_c")
    @studio_x.add_user!(user_c)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @studio_x.handle)

    # User A creates a decision in Studio X
    decision = create_decision(
      tenant: @tenant,
      superagent: @studio_x,
      created_by: @user_a,
      question: "What approach should we take?"
    )

    # User A creates a decision participant for themselves
    participant_a = DecisionParticipantManager.new(decision: decision, user: @user_a).find_or_create_participant

    # User A adds an option that mentions User C in the description
    option = Option.create!(
      tenant: @tenant,
      superagent: @studio_x,
      decision: decision,
      decision_participant: participant_a,
      title: "Option A",
      description: "We should ask @user_c for their expertise on this"
    )

    # Create the event for option creation
    event = Event.create!(
      tenant: @tenant,
      superagent: @studio_x,
      event_type: "option.created",
      actor: @user_a,
      subject: option
    )
    NotificationDispatcher.dispatch(event)

    Superagent.clear_thread_scope

    # Verify User C IS a member of Studio X
    assert @studio_x.user_is_member?(user_c), "Test setup error: User C should be a member of Studio X"

    # User C SHOULD receive a notification because they are mentioned and are a member
    notification_for_user_c = NotificationRecipient.unscoped.find_by(user: user_c)

    assert_not_nil notification_for_user_c,
      "Members should receive notifications when mentioned in option descriptions"
  end
end
