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
# 3. For studio representation: X-Representing-Studio header with the studio's handle
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
    @tenant.enable_api!
    @tenant.create_main_collective!(created_by: @alice)
    @collective = create_collective(tenant: @tenant, created_by: @alice, handle: "api-rep-studio-#{SecureRandom.hex(4)}")
    @collective.add_user!(@alice)
    @collective.add_user!(@bob)
    @collective.enable_api!
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

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
    post "/u/#{@bob.handle}/settings/trustee-grants/#{grant.truncated_id}/actions/start_representation",
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
    post "/u/#{@bob.handle}/settings/trustee-grants/#{grant.truncated_id}/actions/end_representation",
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
      studio_scope: { "mode" => "all" }
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
      studio_scope: { "mode" => "all" }
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

    # Use studio-specific path to ensure note is created in the correct studio
    post "/studios/#{@collective.handle}/note/actions/create_note",
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
  # ACTIVE SESSION WITHOUT HEADER - SHOULD ERROR
  # When a user has an active representation session but makes an API call
  # without the X-Representation-Session-ID header, the API should return
  # an error to prevent accidental actions as the wrong identity.
  # =========================================================================

  test "API rejects request when user has active session but header is missing" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true }
    )
    grant.accept!

    # Bob starts a representation session via API
    session_id = start_representation_session_via_api(grant: grant)

    # Bob makes an API call WITHOUT the X-Representation-Session-ID header
    # Even though the session exists, we're not passing it
    get @collective.path, headers: @headers

    # Should return 409 Conflict with info about active session
    # This forces the API caller to be explicit about their intent
    assert_response :conflict,
                    "API should reject request when user has active representation session " \
                    "but X-Representation-Session-ID header is missing. Got #{response.status}"

    # The error response should include the active session ID so caller can fix their request
    body = response.body
    assert_includes body, session_id,
                    "Error response should include the active session ID"
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
      studio_scope: { "mode" => "all" }
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

    # Create a note via API using studio-specific path
    post "/studios/#{@collective.handle}/note/actions/create_note",
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
      expires_in: 1.hour
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
  # X-REPRESENTING-USER / X-REPRESENTING-STUDIO HEADER TESTS
  # These headers add an extra layer of security by requiring the API client
  # to explicitly know who/what they are representing.
  # =========================================================================

  test "user representation requires X-Representing-User header" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" }
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
      studio_scope: { "mode" => "all" }
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
      studio_scope: { "mode" => "all" }
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

  test "studio representation requires X-Representing-Studio header" do
    # Set up Bob as a representative for the studio
    @collective.collective_members.find_by(user: @bob).add_role!("representative")

    # Create a studio representation session (no trustee_grant, has collective)
    session = RepresentationSession.create!(
      tenant: @tenant,
      collective: @collective,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # Request WITH session ID but WITHOUT X-Representing-Studio header
    headers_without_representing_studio = @headers.merge(
      "X-Representation-Session-ID" => session.id
    )

    get @collective.path, headers: headers_without_representing_studio

    assert_response :forbidden
    assert_includes response.body, "X-Representing-Studio header required"
  end

  test "studio representation rejects wrong X-Representing-Studio header" do
    @collective.collective_members.find_by(user: @bob).add_role!("representative")

    # Create a studio representation session (no trustee_grant, has collective)
    session = RepresentationSession.create!(
      tenant: @tenant,
      collective: @collective,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # Request with WRONG X-Representing-Studio header
    headers_with_wrong_studio = @headers.merge(
      "X-Representation-Session-ID" => session.id,
      "X-Representing-Studio" => "wrong-studio-handle"
    )

    get @collective.path, headers: headers_with_wrong_studio

    assert_response :forbidden
    assert_includes response.body, "does not match the represented studio"
  end

  test "studio representation succeeds with correct X-Representing-Studio header" do
    @collective.collective_members.find_by(user: @bob).add_role!("representative")

    # Create a studio representation session (no trustee_grant, has collective)
    session = RepresentationSession.create!(
      tenant: @tenant,
      collective: @collective,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # Request with CORRECT X-Representing-Studio header
    headers_with_correct_studio = @headers.merge(
      "X-Representation-Session-ID" => session.id,
      "X-Representing-Studio" => @collective.handle
    )

    get @collective.path, headers: headers_with_correct_studio

    assert_response :success
    assert_includes response.body, "acting on behalf of"
  end

  test "ending user representation session does not require X-Representing-User header" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trustee_user: @bob,
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" }
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

  test "ending studio representation session does not require X-Representing-Studio header" do
    @collective.collective_members.find_by(user: @bob).add_role!("representative")

    # Studio representation sessions don't have an API start action yet,
    # so we create directly for this test (no trustee_grant, has collective)
    session = RepresentationSession.create!(
      tenant: @tenant,
      collective: @collective,
      representative_user: @bob,
      confirmed_understanding: true,
      began_at: Time.current,
    )

    # DELETE request with session ID but WITHOUT X-Representing-Studio header should work
    headers_for_end = @headers.merge(
      "X-Representation-Session-ID" => session.id
    )

    delete "/studios/#{@collective.handle}/represent", headers: headers_for_end

    # Should not get a 403 about missing header
    assert_not_equal 403, response.status,
                     "Ending session should not require X-Representing-Studio header"

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
      studio_scope: { "mode" => "all" }
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

    post "/studios/#{@collective.handle}/note/actions/create_note",
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
end
