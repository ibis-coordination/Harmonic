require "test_helper"

class RepresentationSessionTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "rep-session-#{SecureRandom.hex(4)}")
    @user = create_user(email: "rep_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @superagent = create_superagent(tenant: @tenant, created_by: @user, handle: "rep-studio-#{SecureRandom.hex(4)}")
    @superagent.add_user!(@user)
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  # === Validation Tests ===

  test "representation session requires confirmed_understanding to be true" do
    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      confirmed_understanding: false,
      began_at: Time.current,
    )
    assert_not session.valid?
    assert_includes session.errors[:confirmed_understanding], "is not included in the list"
  end

  test "representation session requires began_at" do
    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      confirmed_understanding: true,
      began_at: nil,
    )
    assert_not session.valid?
    assert_includes session.errors[:began_at], "can't be blank"
  end

  test "studio representation session requires superagent" do
    # Studio representation (no trustee_grant) requires superagent_id
    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: nil,
      trustee_grant: nil,
      representative_user: @user,
      confirmed_understanding: true,
      began_at: Time.current,
    )
    assert_not session.valid?
    assert_includes session.errors[:superagent_id], "is required for studio representation sessions"
  end

  test "user representation session must not have superagent" do
    # User representation (has trustee_grant) must NOT have superagent_id
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: create_user(email: "trustee_#{SecureRandom.hex(4)}@example.com"),
      permissions: { "create_notes" => true },
    )

    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: @superagent,
      trustee_grant: grant,
      representative_user: grant.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
    )
    assert_not session.valid?
    assert_includes session.errors[:superagent_id], "must be nil for user representation sessions"
  end

  test "representation session can be created with valid attributes" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert session.persisted?
    assert_equal @user, session.representative_user
    # effective_user returns the studio trustee for studio representation
    assert_equal @superagent.proxy_user, session.effective_user
  end

  # === Lifecycle Tests ===

  test "begin! raises if confirmed_understanding is false" do
    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      confirmed_understanding: false,
    )
    assert_raises RuntimeError, "Must confirm understanding" do
      session.begin!
    end
  end

  test "begin! sets began_at" do
    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      confirmed_understanding: true,
    )
    session.begin!
    assert session.began_at.present?
  end

  test "active? returns true when ended_at is nil" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert session.active?
  end

  test "active? returns false when ended_at is set" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    session.end!
    assert_not session.active?
  end

  test "end! sets ended_at" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_nil session.ended_at
    session.end!
    assert session.ended_at.present?
  end

  test "end! is idempotent" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    session.end!
    first_ended_at = session.ended_at
    session.end!
    assert_equal first_ended_at, session.ended_at
  end

  test "ended? returns true after end! is called" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_not session.ended?
    session.end!
    assert session.ended?
  end

  test "expired? returns true after 24 hours" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
      began_at: 25.hours.ago,
    )
    assert session.expired?
  end

  test "expired? returns false within 24 hours" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
      began_at: 23.hours.ago,
    )
    assert_not session.expired?
  end

  test "expired? returns true when session is ended" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    session.end!
    assert session.expired?
  end

  # === elapsed_time Tests ===

  test "elapsed_time returns seconds since began_at for active session" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
      began_at: 1.hour.ago,
    )
    elapsed = session.elapsed_time
    assert_in_delta 3600, elapsed, 5 # within 5 seconds
  end

  test "elapsed_time returns duration for ended session" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
      began_at: 2.hours.ago,
    )
    travel_to(1.hour.ago) do
      session.end!
    end
    elapsed = session.elapsed_time
    assert_in_delta 3600, elapsed, 5 # 1 hour duration
  end

  # === Event Recording Tests ===

  test "record_event! raises if session has ended" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    session.end!

    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    mock_request = OpenStruct.new(request_id: 'req-123')
    assert_raises RuntimeError, "Session has ended" do
      session.record_event!(
        request: mock_request,
        action_name: "create_note",
        resource: note
      )
    end
  end

  test "record_event! raises if session has expired" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
      began_at: 25.hours.ago,
    )

    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    mock_request = OpenStruct.new(request_id: 'req-123')
    assert_raises RuntimeError, "Session has expired" do
      session.record_event!(
        request: mock_request,
        action_name: "create_note",
        resource: note
      )
    end
  end

  test "record_event! creates RepresentationSessionEvent" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: 'req-123')
    event = session.record_event!(
      request: mock_request,
      action_name: "create_note",
      resource: note
    )

    assert event.persisted?
    assert_equal "create_note", event.action_name
    assert_equal note, event.resource
    assert_equal @superagent.id, event.resource_superagent_id
  end

  test "record_events! creates multiple events" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option1 = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option 1")
    option2 = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option 2")
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: 'req-456')
    session.record_events!(
      request: mock_request,
      action_name: "add_options",
      resources: [option1, option2],
      context_resource: decision
    )

    assert_equal 2, session.representation_session_events.count
    session.representation_session_events.each do |event|
      assert_equal "add_options", event.action_name
      assert_equal decision, event.context_resource
    end
  end

  # === Helper Method Tests ===

  test "title returns truncated_id based title" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_match(/Representation Session \w+/, session.title)
  end

  test "path returns studio-scoped path" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_equal "/studios/#{@superagent.handle}/r/#{session.truncated_id}", session.path
  end

  test "url returns full URL with tenant subdomain" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_match(/#{@tenant.subdomain}.*#{session.truncated_id}/, session.url)
  end

  test "action_count returns 0 for session with no events" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_equal 0, session.action_count
  end

  test "action_count returns count of distinct request_ids" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: 'req-123')
    session.record_event!(
      request: mock_request,
      action_name: "create_note",
      resource: note
    )

    assert_equal 1, session.action_count
  end

  # === API JSON Test ===

  test "api_json returns expected fields" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    json = session.api_json
    assert_equal session.id, json[:id]
    assert_equal true, json[:confirmed_understanding]
    assert json[:began_at].present?
    assert_nil json[:ended_at]
    assert json[:elapsed_time].is_a?(Numeric)
    assert_equal @superagent.id, json[:superagent_id]
    assert_equal @user.id, json[:representative_user_id]
    assert_equal @superagent.proxy_user.id, json[:effective_user_id]
  end

  # =========================================================================
  # USER REPRESENTATION SESSIONS (via TrusteeGrant)
  # These tests document the intended behavior for using representation
  # sessions with trustee grants (user-to-user representation).
  # =========================================================================

  test "user representation session can be created with trustee grant" do
    # Create a second user who will grant permission
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    # Create trustee permission: granting_user grants @user permission to act on their behalf
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    grant.accept!

    # Create user representation session using the trustee grant
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,  # No superagent for user representation
      trustee_grant: grant,
      representative_user: @user,  # The trustee_user who is doing the representing
      confirmed_understanding: true,
      began_at: Time.current,
    )

    assert session.persisted?
    assert session.user_representation?
    assert_equal @user, session.representative_user
    # effective_user returns the granting_user for user representation
    assert_equal granting_user, session.effective_user
  end

  test "user representation session effective_user is the granting user" do
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    grant.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,
      trustee_grant: grant,
      representative_user: @user,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # For user representation, effective_user is the granting_user (who is being represented)
    assert_equal granting_user, session.effective_user
    # This is different from studio representation where effective_user is the studio trustee
  end

  test "user representation session can record events" do
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    grant.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,
      trustee_grant: grant,
      representative_user: @user,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    note = create_note(tenant: @tenant, superagent: @superagent, created_by: granting_user)
    mock_request = OpenStruct.new(request_id: 'req-123')

    event = session.record_event!(
      request: mock_request,
      action_name: "create_note",
      resource: note
    )

    assert_equal 1, session.representation_session_events.count
    assert_equal note, event.resource
  end

  # === Single Session Constraint ===

  test "user cannot have multiple active representation sessions" do
    # First, create a studio representation session
    first_session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert first_session.active?

    # Create another studio
    other_superagent = create_superagent(tenant: @tenant, created_by: @user, handle: "other-studio-#{SecureRandom.hex(4)}")
    other_superagent.add_user!(@user)

    # Attempting to create a second session should fail (or be prevented by business logic)
    # This test documents that we need to enforce single session constraint
    existing_active_session = RepresentationSession.where(
      representative_user: @user,
      ended_at: nil,
    ).where("began_at > ?", 24.hours.ago).first

    assert existing_active_session.present?, "Should find existing active session"
    assert_equal first_session, existing_active_session
  end

  # === User Representation Session Properties ===

  test "user representation session has no superagent" do
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" },
    )
    grant.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,  # User representation has no superagent
      trustee_grant: grant,
      representative_user: @user,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # User representation sessions have no superagent_id
    assert_nil session.superagent
    assert session.user_representation?
  end

  test "user representation session can record events in different studios" do
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    # Create a second studio
    other_superagent = create_superagent(tenant: @tenant, created_by: granting_user, handle: "other-studio-#{SecureRandom.hex(4)}")
    other_superagent.add_user!(@user)
    other_superagent.add_user!(granting_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" },
    )
    grant.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,  # User representation has no superagent
      trustee_grant: grant,
      representative_user: @user,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # Record event in the first studio
    note1 = create_note(tenant: @tenant, superagent: @superagent, created_by: granting_user)
    mock_request = OpenStruct.new(request_id: 'req-123')
    session.record_event!(
      request: mock_request,
      action_name: "create_note",
      resource: note1
    )

    # Record event in a different studio (within the same session)
    note2 = create_note(tenant: @tenant, superagent: other_superagent, created_by: granting_user)
    session.record_event!(
      request: mock_request,
      action_name: "create_note",
      resource: note2
    )

    assert_equal 2, session.representation_session_events.count

    # Verify the resource_superagent_id is captured correctly
    events = session.representation_session_events.order(:created_at)
    assert_equal @superagent.id, events[0].resource_superagent_id
    assert_equal other_superagent.id, events[1].resource_superagent_id
  end

  # === Representation Session with Parent-AiAgent ===

  test "parent can create representation session for ai_agent via auto-created grant" do
    ai_agent = User.create!(
      email: "ai_agent_#{SecureRandom.hex(4)}@example.com",
      name: "Test AiAgent",
      user_type: "ai_agent",
      parent_id: @user.id,
    )
    @tenant.add_user!(ai_agent)
    @superagent.add_user!(ai_agent)

    # Auto-created grant should exist
    grant = TrusteeGrant.find_by(granting_user: ai_agent, trustee_user: @user)
    assert grant.present?, "TrusteeGrant should be auto-created for ai_agent"
    assert grant.active?

    # Parent can create representation session using the trustee grant
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil,  # User representation has no superagent
      trustee_grant: grant,
      representative_user: @user,  # The parent (trustee_user)
      confirmed_understanding: true,
      began_at: Time.current,
    )

    assert session.persisted?
    assert_equal @user, session.representative_user
    assert_equal ai_agent, session.effective_user
    assert session.active?
  end

  # =========================================================================
  # STUDIO REPRESENTATION REGRESSION TESTS
  # These tests protect the existing studio representation behavior.
  # =========================================================================

  test "studio representation session gets correct superagent_id" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    assert_equal @superagent.id, session.superagent_id,
                 "Studio representation session must have correct superagent_id"
  end

  test "studio representation session events get correct superagent_id" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: "req-123")
    event = session.record_event!(
      request: mock_request,
      action_name: "create_note",
      resource: note
    )

    assert_equal @superagent.id, event.superagent_id,
                 "Event must have correct superagent_id"
    assert_equal @superagent.id, event.resource_superagent_id,
                 "Event must have correct resource_superagent_id"
  end

  test "studio representation session is findable via has_many association" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: "req-123")
    session.record_event!(
      request: mock_request,
      action_name: "create_note",
      resource: note
    )

    # Should be able to find events through the session
    assert_equal 1, session.representation_session_events.count
    assert_equal note, session.representation_session_events.first.resource
  end

  test "multiple event recordings in studio session all get correct superagent_id" do
    note1 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    note2 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: "req-123")

    # Record multiple events
    [note1, note2, decision].each do |resource|
      action = resource.is_a?(Decision) ? "create_decision" : "create_note"
      session.record_event!(
        request: mock_request,
        action_name: action,
        resource: resource
      )
    end

    # All events should have correct superagent_id
    session.representation_session_events.each do |event|
      assert_equal @superagent.id, event.superagent_id,
                   "All events must have correct superagent_id"
    end
  end
end
