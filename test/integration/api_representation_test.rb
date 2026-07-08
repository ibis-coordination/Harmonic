# typed: false

require "test_helper"

# Tests for API representation - end-to-end flow.
#
# These tests verify the complete API representation lifecycle:
# 1. Start a representation session via POST to start_representation action
# 2. Use the session ID in the X-Representation-Session-ID header for subsequent requests
# 3. End the session via POST to end_representation action or DELETE to representation endpoint
#
# Design: API representation requires:
# 1. X-Representation-Session-ID header containing the ID of an active RepresentationSession
# 2. For user representation: X-Representing-User header with the granting user's handle
# 3. For collective representation: X-Representing-Collective header with the collective's handle
#
# The X-Representing-* headers add an extra layer of security by requiring the API client
# to know exactly who/what they are representing. This prevents accidental use of the
# wrong representation session.
#
# Session-ending requests (DELETE to representation endpoints) do not require the
# X-Representing-* headers, allowing clients to end sessions without knowing the
# represented entity's handle.
class ApiRepresentationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = create_tenant(subdomain: "api-rep-#{SecureRandom.hex(4)}")
    @alice = create_user(email: "alice_#{SecureRandom.hex(4)}@example.com", name: "Alice")
    @bob = create_user(email: "bob_#{SecureRandom.hex(4)}@example.com", name: "Bob")
    @tenant.add_user!(@alice)
    @tenant.add_user!(@bob)
    mark_activated!(@alice)
    mark_activated!(@bob)
    @tenant.enable_api!
    @tenant.create_main_collective!(created_by: @alice)
    @collective = create_collective(tenant: @tenant, created_by: @alice, handle: "api-rep-collective-#{SecureRandom.hex(4)}")
    @collective.add_user!(@alice)
    @collective.add_user!(@bob)
    @collective.enable_api!
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    @internal_context = AutomationRuleRun.create!(
      tenant: @tenant,
      collective: @collective,
      automation_rule: AutomationRule.create!(
        tenant: @tenant,
        collective: @collective,
        name: "Rep test rule",
        trigger_type: "manual",
        trigger_config: {},
        actions: [],
        created_by: @alice,
      ),
      trigger_source: "manual",
      status: "pending",
    )

    # Create an API token for Bob
    @bob_token = ApiToken.create!(
      tenant: @tenant,
      user: @bob,
      scopes: ApiToken.valid_scopes
    )
    @bob_plaintext_token = @bob_token.plaintext_token

    @headers = {
      "Authorization" => "Bearer #{@bob_plaintext_token}",
      "Accept" => "text/markdown",
    }
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # Helper to start a representation session via the API
  # Returns the session ID (full UUID) from the response
  def start_representation_session_via_api(grant:, headers: @headers)
    post "/settings/trustee-authorizations/#{grant.truncated_id}/actions/start_representation",
         headers: headers

    assert_response :success, "Failed to start representation session: #{response.body}"

    # Extract the session ID from the response (format: "Session ID: `uuid`")
    match = response.body.match(/Session ID: `([a-f0-9-]+)`/)
    assert match, "Response should contain session ID: #{response.body}"
    match[1]
  end

  # Helper to end a representation session via the API
  # The session_id is required to avoid the "active session exists" conflict check
  def end_representation_session_via_api(grant:, session_id:, headers: @headers)
    headers_with_session = headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => grant.granting_user.handle
    )
    post "/settings/trustee-authorizations/#{grant.truncated_id}/actions/end_representation",
         headers: headers_with_session

    assert_response :success, "Failed to end representation session: #{response.body}"
  end

  # Legacy helper for tests that need direct session creation (e.g., testing edge cases)
  def create_representation_session_directly(grant:, representative:)
    RepresentationSession.create!(
      tenant: @tenant,
      collective: nil, # User representation sessions have NULL collective_id
      representative_user: representative,
      trustee_grant: grant,
      confirmed_understanding: true,
      began_at: Time.current,
    )
  end

  # =========================================================================
  # CORE API REPRESENTATION TESTS
  # =========================================================================

  test "API caller can represent via X-Representation-Session-ID header with valid session" do
    # Alice grants Bob permission to act on her behalf
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!

    # Bob starts a representation session via API
    session_id = start_representation_session_via_api(grant: grant)

    # Bob specifies representation via session ID header + X-Representing-User header
    headers_with_representation = @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle
    )

    get @collective.path, headers: headers_with_representation
    assert_response :success

    # The response should indicate Bob is acting as a trustee for Alice
    assert_includes response.body, "acting on behalf of"
  end

  test "notes created via API with representation are attributed to trustee" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!

    # Bob starts a representation session via API
    session_id = start_representation_session_via_api(grant: grant)
    session = RepresentationSession.find(session_id)

    # Bob creates a note via API while representing Alice
    headers_with_representation = @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle
    )

    # Use collective-specific path to ensure note is created in the correct collective
    post "/collectives/#{@collective.handle}/note/actions/create_note",
         params: { title: "Test Note", text: "Created via API as trustee" },
         headers: headers_with_representation
    assert_response :success

    # Find the created note
    note = Note.order(created_at: :desc).first
    assert_not_nil note
    assert_equal "Test Note", note.title

    # Note should be attributed to the effective_user (Alice, the granting_user), not Bob
    assert_equal session.effective_user, note.created_by,
                 "Note should be attributed to effective_user when X-Representation-Session-ID header is set, " \
                 "but was attributed to #{note.created_by.name} (#{note.created_by.user_type})"
  end

  test "API rejects representation with invalid session ID" do
    fake_session_id = SecureRandom.uuid

    headers_with_fake_session = @headers.merge(
      "X-Representation-Session-ID" => fake_session_id
    )

    get @collective.path, headers: headers_with_fake_session

    # Should return 403 Forbidden when session ID is invalid
    assert_response :forbidden,
                    "API should reject representation with invalid session ID, " \
                    "but got #{response.status}"
  end

  test "API rejects representation when session is ended" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant.accept!

    # Bob starts a representation session via API
    session_id = start_representation_session_via_api(grant: grant)

    # End the session via API
    end_representation_session_via_api(grant: grant, session_id: session_id)

    headers_with_ended_session = @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle
    )

    get @collective.path, headers: headers_with_ended_session

    # Should return 403 Forbidden because session is ended
    assert_response :forbidden,
                    "API should reject representation when session is ended, " \
                    "but got #{response.status}"
  end

  test "API rejects representation when grant is revoked" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant.accept!

    # Bob starts a representation session via API
    session_id = start_representation_session_via_api(grant: grant)

    # Alice revokes the grant
    grant.revoke!

    headers_with_revoked_grant = @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle
    )

    get @collective.path, headers: headers_with_revoked_grant

    # Should return 403 Forbidden because grant is revoked
    assert_response :forbidden,
                    "API should reject representation when grant is revoked, " \
                    "but got #{response.status}"
  end

  test "API rejects representation when token user is not the representative" do
    carol = create_user(email: "carol_#{SecureRandom.hex(4)}@example.com", name: "Carol")
    @tenant.add_user!(carol)
    @collective.add_user!(carol)
    mark_activated!(carol)

    # Alice grants Bob (not Carol) permission
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant.accept!

    # Bob starts a representation session via API
    session_id = start_representation_session_via_api(grant: grant)

    # Create a token for Carol
    carol_token = ApiToken.create!(
      tenant: @tenant,
      user: carol,
      scopes: ApiToken.valid_scopes
    )

    # Carol tries to use Bob's representation session (which she's not authorized for)
    carol_headers = {
      "Authorization" => "Bearer #{carol_token.plaintext_token}",
      "Accept" => "text/markdown",
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle,
    }

    get @collective.path, headers: carol_headers

    # Should return 403 Forbidden because Carol is not the session's representative
    assert_response :forbidden,
                    "API should reject representation when token user is not the session's representative, " \
                    "but got #{response.status}"
  end

  # =========================================================================
  # ACTIVE SESSION WITHOUT HEADER - SELF-ACTING WITH WARNING
  # When a user has an active representation session but makes an API call
  # without the X-Representation-Session-ID header, the call succeeds as
  # self-acting and the markdown layout includes a warning surfacing the
  # unattached session and how to either attach it or end it.
  # =========================================================================

  test "self-acting markdown call succeeds when user has an unattached active rep session" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant.accept!

    start_representation_session_via_api(grant: grant)

    get @collective.path, headers: @headers

    assert_response :success,
                    "Self-acting markdown call should succeed when an active rep session exists but is not attached. " \
                    "Got #{response.status}: #{response.body[0..200]}"
  end

  test "markdown layout surfaces a warning when an unattached rep session is active" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant.accept!

    session_id = start_representation_session_via_api(grant: grant)

    get @collective.path, headers: @headers
    assert_response :success

    body = response.body
    assert_includes body, "active representation session",
                    "Warning should announce the unattached active session"
    assert_includes body, session_id,
                    "Warning should include the session id so the agent can attach it"
    assert_includes body, @alice.handle,
                    "Warning should name the represented user"
    assert_includes body, "end_representation",
                    "Warning should tell the agent how to end the session"
    assert_includes body, "representation_session_id",
                    "Warning should reference the MCP context field name agents actually set"
    assert_includes body, "identity.acting_as",
                    "Warning should reference identity.acting_as (the write-side rep handle field)"
    assert_includes body, "identity.viewing_as",
                    "Warning should reference identity.viewing_as (the read-side rep handle field)"
  end

  test "no warning is rendered when the rep session is attached to the request" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!

    session_id = start_representation_session_via_api(grant: grant)

    get @collective.path, headers: @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle,
    )
    assert_response :success
    refute_includes response.body, "active representation session",
                    "No unattached-session warning when the session is attached to the request"
  end

  test "no warning is rendered when the user has no active rep session" do
    get @collective.path, headers: @headers
    assert_response :success
    refute_includes response.body, "active representation session",
                    "No warning when there is no active rep session at all"
  end

  test "warning end path is the handle-free trustee path the actor can self-act on" do
    # Defensive: if an actor has session A attached AND session B unattached
    # (rare under singleton enforcement but possible across mixed browser/API
    # flows), the warning for B must point the agent at the handle-free trustee
    # path, which resolves to THEM (the actor) so they can self-act — not at any
    # grantor-scoped URL they couldn't act under.
    grant_a = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant_a.accept!
    session_a_id = start_representation_session_via_api(grant: grant_a)

    # Construct an additional unattached session for the same trustee, bypassing
    # the singleton check (which only fires on the user-rep start path).
    other_grantor = create_user(email: "other_g_#{SecureRandom.hex(4)}@example.com", name: "Other Grantor")
    @tenant.add_user!(other_grantor)
    mark_activated!(other_grantor)
    @collective.add_user!(other_grantor)
    grant_b = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_grantor,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant_b.accept!
    session_b = RepresentationSession.tenant_scoped_only(@tenant.id).create!(
      tenant: @tenant,
      representative_user: @bob,
      trustee_grant: grant_b,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    get @collective.path, headers: @headers.merge(
      "X-Representation-Session-ID" => session_a_id,
      "X-Representing-User" => @alice.handle,
    )
    assert_response :success
    body = response.body
    assert_includes body, session_b.id,
                    "Warning should call out the unattached session B"
    refute_includes body, session_a_id,
                    "Warning must not list session A (the attached one)"
    assert_includes body, "/settings/trustee-authorizations/#{grant_b.truncated_id}",
                    "End path must be the handle-free trustee path so the actor can self-act on it"
    refute_includes body, "/u/#{other_grantor.handle}/settings/trustee-authorizations/#{grant_b.truncated_id}",
                    "End path must NOT embed the grantor's handle — the trustee can't self-act there"
    refute_includes body, "/u/#{@bob.handle}/settings/trustee-authorizations/#{grant_b.truncated_id}",
                    "End path must be handle-free, not the actor's old /u/<handle> form"
  end

  test "starting a new rep session while one is already active raises with the end recipe" do
    # Pin that the singleton-active-session property is enforced at session
    # creation time (post-gate-drop). The error names the existing session id
    # and the end path so the agent can recover.
    grant_a = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant_a.accept!

    other_grantor = create_user(email: "other_grantor_#{SecureRandom.hex(4)}@example.com", name: "Other Grantor")
    @tenant.add_user!(other_grantor)
    mark_activated!(other_grantor)
    @collective.add_user!(other_grantor)
    grant_b = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_grantor,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant_b.accept!

    session_a_id = start_representation_session_via_api(grant: grant_a)

    # Bob tries to start a second session (on a different grant) without
    # attaching session A. With the gate dropped this used to silently
    # create a second session — now it must error.
    post "/settings/trustee-authorizations/#{grant_b.truncated_id}/actions/start_representation",
         headers: @headers
    refute_equal 200, response.status,
                 "Starting a second concurrent session should fail, got 200 with body: #{response.body[0..300]}"

    body = response.body
    assert_includes body, session_a_id,
                    "Error must name the existing session id so the agent can identify it"
    assert_includes body, "end_representation",
                    "Error must reference the end mechanism"
    assert_includes body, grant_a.truncated_id,
                    "Error's end path must reference the existing session's grant"

    # Only one session was created — the second start did not slip through.
    active_sessions = RepresentationSession.tenant_scoped_only(@tenant.id).where(
      representative_user_id: @bob.id,
      ended_at: nil,
    )
    assert_equal 1, active_sessions.count,
                 "Exactly one active session should exist; the second start must not have created one"
    assert_equal session_a_id, active_sessions.first.id
  end

  test "starting a rep session on the same grant while one is active raises" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant.accept!

    session_a_id = start_representation_session_via_api(grant: grant)

    post "/settings/trustee-authorizations/#{grant.truncated_id}/actions/start_representation",
         headers: @headers
    refute_equal 200, response.status,
                 "Re-starting on the same grant while a session is active should fail"

    active_count = RepresentationSession.tenant_scoped_only(@tenant.id).where(
      representative_user_id: @bob.id,
      ended_at: nil,
    ).count
    assert_equal 1, active_count

    assert_equal session_a_id, RepresentationSession.tenant_scoped_only(@tenant.id).where(
      representative_user_id: @bob.id,
      ended_at: nil,
    ).first.id
  end

  test "starting a rep session after the prior one ended succeeds" do
    grant_a = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant_a.accept!

    session_a_id = start_representation_session_via_api(grant: grant_a)
    RepresentationSession.find(session_a_id).end!

    # Now starting another session should work
    other_grantor = create_user(email: "post_end_grantor_#{SecureRandom.hex(4)}@example.com", name: "Post-end Grantor")
    @tenant.add_user!(other_grantor)
    mark_activated!(other_grantor)
    @collective.add_user!(other_grantor)
    grant_b = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_grantor,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant_b.accept!

    post "/settings/trustee-authorizations/#{grant_b.truncated_id}/actions/start_representation",
         headers: @headers
    assert_response :success, "Starting a new session after the prior one ended should succeed: #{response.body[0..300]}"
  end

  test "warning's prescribed end path actually ends the session when the agent self-acts" do
    # Pin that the end path surfaced in the markdown warning is accessible to
    # the trustee under self-acting auth and actually ends the session. The
    # warning points the trustee at their own /u/<handle>/settings/trustee-
    # authorizations/<grant_id> view (not the grantor's view returned by
    # RepresentationSession#path, which the trustee cannot reach self-acting).
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant.accept!

    session_id = start_representation_session_via_api(grant: grant)
    session = RepresentationSession.find(session_id)
    assert session.active?, "session should be active before end"

    end_path = "/settings/trustee-authorizations/#{grant.truncated_id}/actions/end_representation"

    post end_path, headers: @headers
    assert_response :success, "end_representation at the warning's path should succeed: #{response.body[0..300]}"

    assert session.reload.ended?, "session should be ended after calling the warning's prescribed end path"
  end

  test "note history shows the representative for a note created under representation" do
    # Metadata block at the top of the note already renders "Bob on behalf of
    # Alice" via resource_author_md. The History section below dropped the
    # representative and showed only "Alice created this note" — same data,
    # two surfaces, inconsistent shape. Pin the corrected attribution.
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_note" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!
    session_id = start_representation_session_via_api(grant: grant)

    post "/collectives/#{@collective.handle}/note/actions/create_note",
         params: { title: "Rep'd note", text: "Posted under rep" },
         headers: @headers.merge(
           "X-Representation-Session-ID" => session_id,
           "X-Representing-User" => @alice.handle,
         )
    assert_response :success
    note = Note.where(title: "Rep'd note").last
    assert note, "note should have been created"
    assert note.created_via_representation?, "note should be flagged as rep-created"

    get note.path, headers: @headers
    assert_response :success
    body = response.body

    history_section = body.split("## History").last
    assert history_section, "show page should have a History section"
    create_line = history_section.lines.find { |l| l.include?("created this note") }
    assert create_line, "History section should have a 'created this note' line"
    assert_includes create_line, @bob.handle,
                    "Create line should name the representative (#{@bob.handle})"
    assert_includes create_line, "on behalf of",
                    "Create line should use the 'on behalf of' shape from resource_author_md"
    assert_includes create_line, @alice.handle,
                    "Create line should name the represented user (#{@alice.handle})"
  end

  test "creating a note under rep auto-confirms the representative, not the represented user" do
    # The Note `after_create` hook records a `read_confirmation` for the
    # author. Under rep, `created_by` is the represented user — who did NOT
    # actually see the note — so the read-confirmation was inflating reader
    # counts with a falsehood. Pin that the representative gets the auto-
    # confirmation, and the represented user does not.
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_note" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!
    session_id = start_representation_session_via_api(grant: grant)

    post "/collectives/#{@collective.handle}/note/actions/create_note",
         params: { title: "Rep'd note", text: "Posted under rep" },
         headers: @headers.merge(
           "X-Representation-Session-ID" => session_id,
           "X-Representing-User" => @alice.handle,
         )
    assert_response :success
    note = Note.where(title: "Rep'd note").last
    assert note, "note should have been created"

    confirmations = NoteHistoryEvent.where(note: note, event_type: "read_confirmation")
    assert_equal [@bob.id], confirmations.pluck(:user_id),
                 "Only the representative should have an auto-read-confirmation; the represented user must not be implicitly marked as having read the note"
  end

  test "creating a comment under rep auto-confirms the representative on parent and comment" do
    # The Note `after_create` hook also auto-confirms the parent (commentable)
    # when the new note is a comment — same falsehood under rep. The
    # representative read the parent (they had to in order to reply); the
    # represented user did not.
    parent_collective_member = create_user(email: "parent_author_#{SecureRandom.hex(4)}@example.com", name: "Parent Author")
    @tenant.add_user!(parent_collective_member)
    mark_activated!(parent_collective_member)
    @collective.add_user!(parent_collective_member)
    parent_note = create_note(tenant: @tenant, collective: @collective, created_by: parent_collective_member, title: "Parent")

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_note" => true, "add_comment" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!
    session_id = start_representation_session_via_api(grant: grant)

    post "#{parent_note.path}/actions/add_comment",
         params: { text: "Reply under rep" },
         headers: @headers.merge(
           "X-Representation-Session-ID" => session_id,
           "X-Representing-User" => @alice.handle,
         )
    assert_response :success
    comment = Note.where(text: "Reply under rep").last
    assert comment, "comment should have been created"

    comment_confirmations = NoteHistoryEvent.where(note: comment, event_type: "read_confirmation").pluck(:user_id)
    assert_includes comment_confirmations, @bob.id, "Representative should be auto-confirmed on the comment"
    refute_includes comment_confirmations, @alice.id, "Represented user must not be auto-confirmed on the comment"

    parent_confirmations = NoteHistoryEvent.where(note: parent_note, event_type: "read_confirmation").pluck(:user_id)
    assert_includes parent_confirmations, @bob.id, "Representative should be auto-confirmed on the parent (they read it in order to reply)"
    refute_includes parent_confirmations, @alice.id, "Represented user must not be auto-confirmed on the parent"
  end

  test "note history shows a single user for a note created without representation" do
    # Regression guard: the rep-aware attribution must not change the shape
    # of the history line when no representation was involved.
    note = create_note(tenant: @tenant, collective: @collective, created_by: @bob, title: "Plain note", text: "Self-acting")

    get note.path, headers: @headers
    assert_response :success
    body = response.body

    history_section = body.split("## History").last
    create_line = history_section.lines.find { |l| l.include?("created this note") }
    assert create_line, "History section should have a 'created this note' line"
    refute_includes create_line, "on behalf of",
                    "Plain note's create line should not include rep attribution"
    assert_includes create_line, @bob.handle
  end

  # =========================================================================
  # REPRESENTATION SESSION ACTIVITY LOGGING
  # =========================================================================

  test "API actions with representation are logged to the session" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!

    # Bob starts a representation session via API
    session_id = start_representation_session_via_api(grant: grant)
    session = RepresentationSession.find(session_id)
    initial_action_count = session.action_count

    headers_with_representation = @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle
    )

    # Create a note via API using collective-specific path
    post "/collectives/#{@collective.handle}/note/actions/create_note",
         params: { title: "Logged Note", text: "This should be logged" },
         headers: headers_with_representation
    assert_response :success

    # The action should be logged to the representation session
    session.reload
    assert_equal initial_action_count + 1, session.action_count,
                 "API action should be logged to the representation session"
  end

  # =========================================================================
  # DESIGN QUESTION: INTERNAL TOKENS
  # =========================================================================

  test "internal tokens work without representation (baseline behavior)" do
    # This test just verifies internal tokens work normally
    # Design question: should internal tokens support representation?
    internal_token = ApiToken.create_internal_token(
      user: @bob,
      tenant: @tenant,
      context: @internal_context,
      expires_in: 1.hour,
    )

    internal_headers = {
      "Authorization" => "Bearer #{internal_token.plaintext_token}",
      "Accept" => "text/markdown",
    }

    get @collective.path, headers: internal_headers
    assert_response :success

    # Currently acts as Bob
    assert_includes response.body, @bob.name
  end

  # =========================================================================
  # X-REPRESENTING-USER / X-REPRESENTING-COLLECTIVE HEADER TESTS
  # These headers add an extra layer of security by requiring the API client
  # to explicitly know who/what they are representing.
  # =========================================================================

  test "user representation requires X-Representing-User header" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!

    # Start session via API
    session_id = start_representation_session_via_api(grant: grant)

    # Request WITH session ID but WITHOUT X-Representing-User header
    headers_without_representing_user = @headers.merge(
      "X-Representation-Session-ID" => session_id
    )

    get @collective.path, headers: headers_without_representing_user

    assert_response :forbidden
    assert_includes response.body, "X-Representing-User header required"
  end

  test "user representation rejects wrong X-Representing-User header" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!

    # Start session via API
    session_id = start_representation_session_via_api(grant: grant)

    # Request with WRONG X-Representing-User header
    headers_with_wrong_user = @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => "wrong-handle"
    )

    get @collective.path, headers: headers_with_wrong_user

    assert_response :forbidden
    assert_includes response.body, "does not match the represented user"
  end

  test "user representation succeeds with correct X-Representing-User header" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!

    # Start session via API
    session_id = start_representation_session_via_api(grant: grant)

    # Request with CORRECT X-Representing-User header
    headers_with_correct_user = @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle
    )

    get @collective.path, headers: headers_with_correct_user

    assert_response :success
    assert_includes response.body, "acting on behalf of"
  end

  test "collective representation requires X-Representing-Collective header" do
    # Set up Bob as a representative for the collective
    @collective.collective_members.find_by(user: @bob).add_role!("representative")

    # Create a collective representation session (no trustee_grant, has collective)
    session = RepresentationSession.create!(
      tenant: @tenant,
      collective: @collective,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # Request WITH session ID but WITHOUT X-Representing-Collective header
    headers_without_representing_collective = @headers.merge(
      "X-Representation-Session-ID" => session.id
    )

    get @collective.path, headers: headers_without_representing_collective

    assert_response :forbidden
    assert_includes response.body, "X-Representing-Collective header required"
  end

  test "collective representation rejects wrong X-Representing-Collective header" do
    @collective.collective_members.find_by(user: @bob).add_role!("representative")

    # Create a collective representation session (no trustee_grant, has collective)
    session = RepresentationSession.create!(
      tenant: @tenant,
      collective: @collective,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # Request with WRONG X-Representing-Collective header
    headers_with_wrong_collective = @headers.merge(
      "X-Representation-Session-ID" => session.id,
      "X-Representing-Collective" => "wrong-collective-handle"
    )

    get @collective.path, headers: headers_with_wrong_collective

    assert_response :forbidden
    assert_includes response.body, "does not match the represented collective"
  end

  test "collective representation succeeds with correct X-Representing-Collective header" do
    @collective.collective_members.find_by(user: @bob).add_role!("representative")

    # Create a collective representation session (no trustee_grant, has collective)
    session = RepresentationSession.create!(
      tenant: @tenant,
      collective: @collective,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # Request with CORRECT X-Representing-Collective header
    headers_with_correct_collective = @headers.merge(
      "X-Representation-Session-ID" => session.id,
      "X-Representing-Collective" => @collective.handle
    )

    get @collective.path, headers: headers_with_correct_collective

    assert_response :success
    assert_includes response.body, "acting on behalf of"
  end

  test "ending user representation session does not require X-Representing-User header" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!

    # Start session via API
    session_id = start_representation_session_via_api(grant: grant)

    # DELETE request with session ID but WITHOUT X-Representing-User header should work
    headers_for_end = @headers.merge(
      "X-Representation-Session-ID" => session_id
    )

    delete "/representing", headers: headers_for_end

    # Should not get a 403 about missing header
    assert_not_equal 403, response.status,
                     "Ending session should not require X-Representing-User header"

    # Verify session was actually ended
    session = RepresentationSession.find(session_id)
    assert session.ended?, "Session should be ended after DELETE request"
  end

  test "ending collective representation session does not require X-Representing-Collective header" do
    @collective.collective_members.find_by(user: @bob).add_role!("representative")

    # Collective representation sessions don't have an API start action yet,
    # so we create directly for this test (no trustee_grant, has collective)
    session = RepresentationSession.create!(
      tenant: @tenant,
      collective: @collective,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # DELETE request with session ID but WITHOUT X-Representing-Collective header should work
    headers_for_end = @headers.merge(
      "X-Representation-Session-ID" => session.id
    )

    delete "/collectives/#{@collective.handle}/represent", headers: headers_for_end

    # Should not get a 403 about missing header
    assert_not_equal 403, response.status,
                     "Ending session should not require X-Representing-Collective header"

    # Verify session was actually ended
    session.reload
    assert session.ended?, "Session should be ended after DELETE request"
  end

  # =========================================================================
  # END-TO-END API FLOW TESTS
  # These tests verify the complete lifecycle via API endpoints
  # =========================================================================

  test "complete user representation lifecycle via API" do
    # Create and accept a trustee grant
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      collective_scope: { "mode" => "all" }
    )
    grant.accept!

    # Step 1: Start representation session via API
    session_id = start_representation_session_via_api(grant: grant)
    assert_not_nil session_id, "Should receive session ID from start_representation"

    # Step 2: Use the session to perform actions
    headers_with_representation = @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle
    )

    post "/collectives/#{@collective.handle}/note/actions/create_note",
         params: { title: "E2E Test Note", text: "Created in end-to-end test" },
         headers: headers_with_representation
    assert_response :success

    # Verify note was created by effective_user (the granting_user)
    note = Note.order(created_at: :desc).first
    session = RepresentationSession.find(session_id)
    assert_equal session.effective_user, note.created_by

    # Step 3: End representation session via API
    end_representation_session_via_api(grant: grant, session_id: session_id)

    # Verify session is ended
    session.reload
    assert session.ended?, "Session should be ended after end_representation"

    # Step 4: Verify session ID no longer works
    get @collective.path, headers: headers_with_representation
    assert_response :forbidden, "Ended session should be rejected"
  end

  test "GET /representing renders markdown for API/MCP callers under an active session" do
    # The /representing page is the documented recovery surface for agents
    # who lose track of their active rep state. Without a markdown template,
    # an MCP client requesting it crashes with ActionController::UnknownFormat.
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: @alice, trustee_user: @bob,
      permissions: nil, collective_scope: { "mode" => "all" },
    )
    grant.accept!
    session_id = start_representation_session_via_api(grant: grant)

    get "/representing", headers: @headers.merge(
      "X-Representation-Session-ID" => session_id,
      "X-Representing-User" => @alice.handle,
    )

    assert_response :success
    assert_equal "text/markdown; charset=utf-8", response.headers["Content-Type"]
    assert_match(/Representing|representation/i, response.body)
  end
end
