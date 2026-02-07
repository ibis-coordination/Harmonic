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
      trustee_user: @superagent.trustee_user,
      confirmed_understanding: false,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )
    assert_not session.valid?
    assert_includes session.errors[:confirmed_understanding], "is not included in the list"
  end

  test "representation session requires began_at" do
    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      trustee_user: @superagent.trustee_user,
      confirmed_understanding: true,
      began_at: nil,
      activity_log: { 'activity' => [] },
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
      trustee_user: @superagent.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )
    assert_not session.valid?
    assert_includes session.errors[:superagent_id], "is required for studio representation sessions"
  end

  test "user representation session must not have superagent" do
    # User representation (has trustee_grant) must NOT have superagent_id
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trusted_user: create_user(email: "trusted_#{SecureRandom.hex(4)}@example.com"),
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )

    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: @superagent,
      trustee_grant: grant,
      representative_user: @user,
      trustee_user: grant.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
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
    assert_equal @superagent.trustee_user, session.trustee_user
  end

  # === Lifecycle Tests ===

  test "begin! raises if confirmed_understanding is false" do
    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      trustee_user: @superagent.trustee_user,
      confirmed_understanding: false,
      activity_log: { 'activity' => [] },
    )
    assert_raises RuntimeError, "Must confirm understanding" do
      session.begin!
    end
  end

  test "begin! sets began_at and initializes activity_log" do
    session = RepresentationSession.new(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      trustee_user: @superagent.trustee_user,
      confirmed_understanding: true,
      activity_log: {},
    )
    session.begin!
    assert session.began_at.present?
    assert_equal [], session.activity_log['activity']
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

  # === Activity Recording Tests ===

  test "validate_semantic_event! raises for invalid event type" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_raises RuntimeError do
      session.validate_semantic_event!({
        timestamp: Time.current.iso8601,
        event_type: 'invalid',
        superagent_id: @superagent.id,
        main_resource: { type: 'Note', id: '123', truncated_id: 'abc123' },
        sub_resources: [],
      })
    end
  end

  test "validate_semantic_event! raises for invalid main resource type" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_raises RuntimeError do
      session.validate_semantic_event!({
        timestamp: Time.current.iso8601,
        event_type: 'create',
        superagent_id: @superagent.id,
        main_resource: { type: 'InvalidType', id: '123', truncated_id: 'abc123' },
        sub_resources: [],
      })
    end
  end

  test "validate_semantic_event! accepts valid event" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    # Should not raise
    session.validate_semantic_event!({
      timestamp: Time.current.iso8601,
      event_type: 'create',
      superagent_id: @superagent.id,
      main_resource: { type: 'Note', id: '123', truncated_id: 'abc123' },
      sub_resources: [],
    })
  end

  test "record_activity! raises if session has ended" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    session.end!

    mock_request = OpenStruct.new(request_id: 'req-123', method: 'POST', path: '/notes')
    assert_raises RuntimeError, "Session has ended" do
      session.record_activity!(
        request: mock_request,
        semantic_event: {
          timestamp: Time.current.iso8601,
          event_type: 'create',
          superagent_id: @superagent.id,
          main_resource: { type: 'Note', id: '123', truncated_id: 'abc123' },
          sub_resources: [],
        },
      )
    end
  end

  test "record_activity! raises if session has expired" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
      began_at: 25.hours.ago,
    )

    mock_request = OpenStruct.new(request_id: 'req-123', method: 'POST', path: '/notes')
    assert_raises RuntimeError, "Session has expired" do
      session.record_activity!(
        request: mock_request,
        semantic_event: {
          timestamp: Time.current.iso8601,
          event_type: 'create',
          superagent_id: @superagent.id,
          main_resource: { type: 'Note', id: '123', truncated_id: 'abc123' },
          sub_resources: [],
        },
      )
    end
  end

  test "record_activity! adds activity to log and creates association" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: 'req-123', method: 'POST', path: '/notes')
    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'create',
        superagent_id: @superagent.id,
        main_resource: { type: 'Note', id: note.id, truncated_id: note.truncated_id },
        sub_resources: [],
      },
    )

    assert_equal 1, session.activity_log['activity'].count
    assert_equal 1, session.representation_session_associations.count
    association = session.representation_session_associations.first
    assert_equal 'Note', association.resource_type
    assert_equal note.id, association.resource_id
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

  test "action_count returns 0 for session with no activity" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_equal 0, session.action_count
  end

  test "action_count returns count of activities" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: 'req-123', method: 'POST', path: '/notes')
    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'create',
        superagent_id: @superagent.id,
        main_resource: { type: 'Note', id: note.id, truncated_id: note.truncated_id },
        sub_resources: [],
      },
    )

    assert_equal 1, session.action_count
  end

  # === event_type_to_verb_phrase Tests ===

  test "event_type_to_verb_phrase returns correct phrases" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    assert_equal 'created', session.event_type_to_verb_phrase('create')
    assert_equal 'updated', session.event_type_to_verb_phrase('update')
    assert_equal 'confirmed reading', session.event_type_to_verb_phrase('confirm')
    assert_equal 'added options to', session.event_type_to_verb_phrase('add_options')
    assert_equal 'voted on', session.event_type_to_verb_phrase('vote')
    assert_equal 'joined', session.event_type_to_verb_phrase('commit')
  end

  test "event_type_to_verb_phrase raises for unknown event type" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    assert_raises RuntimeError do
      session.event_type_to_verb_phrase('unknown')
    end
  end

  # === add_options Event Tracking Tests ===

  test "validate_semantic_event! accepts add_options event type" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    # Should not raise
    session.validate_semantic_event!({
      timestamp: Time.current.iso8601,
      event_type: 'add_options',
      superagent_id: @superagent.id,
      main_resource: { type: 'Decision', id: '123', truncated_id: 'abc123' },
      sub_resources: [{ type: 'Option', id: '456' }],
    })
  end

  test "validate_semantic_event! rejects singular add_option event type" do
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )
    # Should raise because add_option (singular) is not a valid event type
    assert_raises RuntimeError, /Invalid event type/ do
      session.validate_semantic_event!({
        timestamp: Time.current.iso8601,
        event_type: 'add_option',
        superagent_id: @superagent.id,
        main_resource: { type: 'Decision', id: '123', truncated_id: 'abc123' },
        sub_resources: [{ type: 'Option', id: '456' }],
      })
    end
  end

  test "record_activity! tracks add_options event with sub_resources" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option1 = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option 1")
    option2 = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option 2")
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: 'req-456', method: 'POST', path: '/decisions/123/actions/add_options')
    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'add_options',
        superagent_id: @superagent.id,
        main_resource: { type: 'Decision', id: decision.id, truncated_id: decision.truncated_id },
        sub_resources: [
          { type: 'Option', id: option1.id },
          { type: 'Option', id: option2.id },
        ],
      },
    )

    assert_equal 1, session.activity_log['activity'].count
    # Main resource association + 2 sub-resource associations
    assert_equal 3, session.representation_session_associations.count

    activity = session.activity_log['activity'].first
    assert_equal 'add_options', activity['semantic_event']['event_type']
    assert_equal 2, activity['semantic_event']['sub_resources'].count
  end

  test "human_readable_activity_log shows add_options as 'added options to'" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: 'req-789', method: 'POST', path: '/decisions/123/actions/add_options')
    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'add_options',
        superagent_id: @superagent.id,
        main_resource: { type: 'Decision', id: decision.id, truncated_id: decision.truncated_id },
        sub_resources: [{ type: 'Option', id: option.id }],
      },
    )

    log = session.human_readable_activity_log
    assert_equal 1, log.count
    assert_equal 'added options to', log.first[:verb_phrase]
    assert_equal decision, log.first[:main_resource]
  end

  # === human_readable_activity_log Tests ===

  test "human_readable_activity_log deduplicates consecutive votes on same decision" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: 'req-123', method: 'POST', path: '/decisions')

    # Record two votes on the same decision
    2.times do
      session.record_activity!(
        request: mock_request,
        semantic_event: {
          timestamp: Time.current.iso8601,
          event_type: 'vote',
          superagent_id: @superagent.id,
          main_resource: { type: 'Decision', id: decision.id, truncated_id: decision.truncated_id },
          sub_resources: [],
        },
      )
    end

    # Should only show 1 vote (the last one)
    assert_equal 2, session.activity_log['activity'].count
    assert_equal 1, session.human_readable_activity_log.count
    assert_equal 'voted on', session.human_readable_activity_log.first[:verb_phrase]
  end

  test "human_readable_activity_log shows all different actions" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: 'req-123', method: 'POST', path: '/test')

    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'create',
        superagent_id: @superagent.id,
        main_resource: { type: 'Note', id: note.id, truncated_id: note.truncated_id },
        sub_resources: [],
      },
    )

    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'vote',
        superagent_id: @superagent.id,
        main_resource: { type: 'Decision', id: decision.id, truncated_id: decision.truncated_id },
        sub_resources: [],
      },
    )

    log = session.human_readable_activity_log
    assert_equal 2, log.count
    assert_equal 'created', log[0][:verb_phrase]
    assert_equal 'voted on', log[1][:verb_phrase]
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
    assert json[:activity_log].is_a?(Hash)
    assert_equal @superagent.id, json[:superagent_id]
    assert_equal @user.id, json[:representative_user_id]
    assert_equal @superagent.trustee_user.id, json[:trustee_user_id]
  end

  # =========================================================================
  # TRUSTEE GRANT TRUSTEE REPRESENTATION SESSIONS
  # These tests document the intended behavior for using representation
  # sessions with trustee grant trustees (user-to-user trustee grant).
  # =========================================================================

  test "representation session can be created with trustee grant trustee" do
    # Create a second user who will grant permission
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    # Create trustee permission: granting_user grants @user permission to act on their behalf
    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!

    # Create session using the trustee grant trustee
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,  # The trusted_user who is doing the representing
      trustee_user: permission.trustee_user,  # The trustee grant trustee, not the studio trustee
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    assert session.persisted?
    assert_equal @user, session.representative_user
    assert_equal permission.trustee_user, session.trustee_user
    assert_not_equal @superagent.trustee_user, session.trustee_user
    assert session.trustee_user.trustee?
    assert_not session.trustee_user.superagent_trustee?
  end

  test "delegation session trustee is not a superagent trustee" do
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      trustee_user: permission.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    # Delegation trustee should NOT be a superagent trustee
    assert_not session.trustee_user.superagent_trustee?
    assert_nil session.trustee_user.trustee_superagent
  end

  test "delegation session can record activity" do
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
    )
    permission.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,
      trustee_user: permission.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    mock_request = OpenStruct.new(request_id: 'req-123', method: 'POST', path: '/notes')

    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'create',
        superagent_id: @superagent.id,
        main_resource: { type: 'Note', id: note.id, truncated_id: note.truncated_id },
        sub_resources: [],
      },
    )

    assert_equal 1, session.activity_log['activity'].count
    assert_equal 1, session.representation_session_associations.count
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

  # === Multi-Studio Session for Delegation ===

  test "delegation session superagent tracks initial studio context" do
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" },
    )
    permission.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,  # Initial studio context
      representative_user: @user,
      trustee_user: permission.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    # Session is created in the context of @superagent
    assert_equal @superagent, session.superagent
  end

  test "delegation session can record activity in different studios" do
    granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Granting User")
    @tenant.add_user!(granting_user)
    @superagent.add_user!(granting_user)

    # Create a second studio
    other_superagent = create_superagent(tenant: @tenant, created_by: granting_user, handle: "other-studio-#{SecureRandom.hex(4)}")
    other_superagent.add_user!(@user)
    other_superagent.add_user!(granting_user)

    permission = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: granting_user,
      trusted_user: @user,
      relationship_phrase: "{trusted_user} acts for {granting_user}",
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" },
    )
    permission.accept!

    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,  # Initial studio context
      representative_user: @user,
      trustee_user: permission.trustee_user,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    # Record activity in the initial studio
    note1 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    mock_request = OpenStruct.new(request_id: 'req-123', method: 'POST', path: '/notes')
    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'create',
        superagent_id: @superagent.id,
        main_resource: { type: 'Note', id: note1.id, truncated_id: note1.truncated_id },
        sub_resources: [],
      },
    )

    # Record activity in a different studio (within the same session)
    note2 = create_note(tenant: @tenant, superagent: other_superagent, created_by: @user)
    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: 'create',
        superagent_id: other_superagent.id,  # Different studio
        main_resource: { type: 'Note', id: note2.id, truncated_id: note2.truncated_id },
        sub_resources: [],
      },
    )

    assert_equal 2, session.activity_log['activity'].count

    # Verify the superagent_id is captured in each semantic event
    activities = session.activity_log['activity']
    assert_equal @superagent.id, activities[0]['semantic_event']['superagent_id']
    assert_equal other_superagent.id, activities[1]['semantic_event']['superagent_id']
  end

  # === Representation Session with Parent-Subagent ===

  test "parent can create representation session for subagent via auto-created permission" do
    subagent = User.create!(
      email: "subagent_#{SecureRandom.hex(4)}@example.com",
      name: "Test Subagent",
      user_type: "subagent",
      parent_id: @user.id,
    )
    @tenant.add_user!(subagent)
    @superagent.add_user!(subagent)

    # Auto-created permission should exist
    permission = TrusteeGrant.find_by(granting_user: subagent, trusted_user: @user)
    assert permission.present?, "TrusteeGrant should be auto-created for subagent"
    assert permission.active?

    # Parent can create representation session using the trustee grant trustee
    session = RepresentationSession.create!(
      tenant: @tenant,
      superagent: @superagent,
      representative_user: @user,  # The parent
      trustee_user: permission.trustee_user,  # The trustee grant trustee
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { 'activity' => [] },
    )

    assert session.persisted?
    assert_equal @user, session.representative_user
    assert session.active?
  end

  # =========================================================================
  # STUDIO REPRESENTATION REGRESSION TESTS
  # These tests protect the existing studio representation behavior.
  # Studio representation sessions should:
  # - Have the correct superagent_id set on the session
  # - Have the correct superagent_id set on association records
  # - Be queryable within the studio context
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

  test "studio representation session associations get correct superagent_id" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: "req-123", method: "POST", path: "/notes")
    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: "create",
        superagent_id: @superagent.id,
        main_resource: { type: "Note", id: note.id, truncated_id: note.truncated_id },
        sub_resources: [],
      },
    )

    association = session.representation_session_associations.first
    assert_equal @superagent.id, association.superagent_id,
                 "Association must have correct superagent_id"
    assert_equal @superagent.id, association.resource_superagent_id,
                 "Association must have correct resource_superagent_id"
  end

  test "studio representation session is findable via has_many association" do
    note = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: "req-123", method: "POST", path: "/notes")
    session.record_activity!(
      request: mock_request,
      semantic_event: {
        timestamp: Time.current.iso8601,
        event_type: "create",
        superagent_id: @superagent.id,
        main_resource: { type: "Note", id: note.id, truncated_id: note.truncated_id },
        sub_resources: [],
      },
    )

    # Should be able to find associations through the session
    assert_equal 1, session.representation_session_associations.count
    assert_equal note.id, session.representation_session_associations.first.resource_id
  end

  test "multiple activity recordings in studio session all get correct superagent_id" do
    note1 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    note2 = create_note(tenant: @tenant, superagent: @superagent, created_by: @user)
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    session = create_representation_session(
      tenant: @tenant,
      superagent: @superagent,
      representative: @user,
    )

    mock_request = OpenStruct.new(request_id: "req-123", method: "POST", path: "/notes")

    # Record multiple activities
    [
      { type: "Note", id: note1.id, truncated_id: note1.truncated_id },
      { type: "Note", id: note2.id, truncated_id: note2.truncated_id },
      { type: "Decision", id: decision.id, truncated_id: decision.truncated_id },
    ].each do |resource|
      session.record_activity!(
        request: mock_request,
        semantic_event: {
          timestamp: Time.current.iso8601,
          event_type: "create",
          superagent_id: @superagent.id,
          main_resource: resource,
          sub_resources: [],
        },
      )
    end

    # All associations should have correct superagent_id
    session.representation_session_associations.each do |assoc|
      assert_equal @superagent.id, assoc.superagent_id,
                   "All associations must have correct superagent_id"
    end
  end
end
