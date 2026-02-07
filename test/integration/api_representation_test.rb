# typed: false

require "test_helper"

# Tests for API representation - these tests FAIL to expose the gap in implementation.
# See ApplicationController#resolve_api_user: "TODO: Handle representation through the API"
#
# Design: API representation requires an X-Representation-Session-ID header containing
# the ID of an active RepresentationSession. This mirrors the browser flow where a
# representation session must be started before acting as a trustee.
#
# When the feature is implemented, these tests should pass.
class ApiRepresentationTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = create_tenant(subdomain: "api-rep-#{SecureRandom.hex(4)}")
    @alice = create_user(email: "alice_#{SecureRandom.hex(4)}@example.com", name: "Alice")
    @bob = create_user(email: "bob_#{SecureRandom.hex(4)}@example.com", name: "Bob")
    @tenant.add_user!(@alice)
    @tenant.add_user!(@bob)
    @tenant.enable_api!
    @tenant.create_main_superagent!(created_by: @alice)
    @superagent = create_superagent(tenant: @tenant, created_by: @alice, handle: "api-rep-studio-#{SecureRandom.hex(4)}")
    @superagent.add_user!(@alice)
    @superagent.add_user!(@bob)
    @superagent.enable_api!
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)

    # Create an API token for Bob
    @bob_token = ApiToken.create!(
      tenant: @tenant,
      user: @bob,
      scopes: ApiToken.valid_scopes,
    )
    @bob_plaintext_token = @bob_token.plaintext_token

    @headers = {
      "Authorization" => "Bearer #{@bob_plaintext_token}",
      "Accept" => "text/markdown",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # Helper to create a representation session for testing
  # In the real implementation, this would be done via an API endpoint
  def create_representation_session_for(grant:, representative:)
    RepresentationSession.create!(
      tenant: @tenant,
      superagent: nil, # User representation sessions have NULL superagent_id
      representative_user: representative,
      trustee_user: grant.trustee_user,
      trustee_grant: grant,
      confirmed_understanding: true,
      began_at: Time.current,
      activity_log: { "activity" => [] }
    )
  end

  # =========================================================================
  # FAILING TESTS: API REPRESENTATION NOT YET IMPLEMENTED
  # These tests assert expected behavior. They will FAIL until the feature is built.
  # =========================================================================

  test "FAILING: API caller can represent via X-Representation-Session-ID header with valid session" do
    # Alice grants Bob permission to act on her behalf
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "Bob acts for Alice",
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" },
    )
    grant.accept!

    # Bob starts a representation session (in reality, this would be via API)
    session = create_representation_session_for(grant: grant, representative: @bob)

    # Bob specifies representation via session ID header
    headers_with_representation = @headers.merge(
      "X-Representation-Session-ID" => session.id
    )

    get @superagent.path, headers: headers_with_representation
    assert_response :success

    # EXPECTED: The response should indicate Bob is acting as a trustee for Alice
    # This will FAIL because the feature is not implemented
    assert_includes response.body, "acting on behalf of",
                    "API representation via X-Representation-Session-ID header is not implemented"
  end

  test "FAILING: notes created via API with representation are attributed to trustee" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "Bob acts for Alice",
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" },
    )
    grant.accept!

    # Bob starts a representation session
    session = create_representation_session_for(grant: grant, representative: @bob)

    # Switch to the studio context for the API call
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)

    # Bob creates a note via API while representing Alice
    headers_with_representation = @headers.merge(
      "X-Representation-Session-ID" => session.id
    )

    post "/note/actions/create_note",
         params: { title: "Test Note", text: "Created via API as trustee" },
         headers: headers_with_representation
    assert_response :success

    # Find the created note
    note = Note.order(created_at: :desc).first
    assert_not_nil note
    assert_equal "Test Note", note.title

    # EXPECTED: Note should be attributed to the trustee_user, not Bob
    # This will FAIL because representation header is ignored
    assert_equal session.trustee_user, note.created_by,
                 "Note should be attributed to trustee_user when X-Representation-Session-ID header is set, " \
                 "but was attributed to #{note.created_by.name} (#{note.created_by.user_type})"
  end

  test "FAILING: API rejects representation with invalid session ID" do
    fake_session_id = SecureRandom.uuid

    headers_with_fake_session = @headers.merge(
      "X-Representation-Session-ID" => fake_session_id
    )

    get @superagent.path, headers: headers_with_fake_session

    # EXPECTED: Should return 403 Forbidden when session ID is invalid
    # This will FAIL because the header is currently ignored
    assert_response :forbidden,
                    "API should reject representation with invalid session ID, " \
                    "but got #{response.status}"
  end

  test "FAILING: API rejects representation when session is ended" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "Bob acts for Alice",
      permissions: { "create_notes" => true },
    )
    grant.accept!

    # Bob starts and then ends a representation session
    session = create_representation_session_for(grant: grant, representative: @bob)
    session.end!

    headers_with_ended_session = @headers.merge(
      "X-Representation-Session-ID" => session.id
    )

    get @superagent.path, headers: headers_with_ended_session

    # EXPECTED: Should return 403 Forbidden because session is ended
    # This will FAIL because the header is currently ignored
    assert_response :forbidden,
                    "API should reject representation when session is ended, " \
                    "but got #{response.status}"
  end

  test "FAILING: API rejects representation when grant is revoked" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "Bob acts for Alice",
      permissions: { "create_notes" => true },
    )
    grant.accept!

    # Bob starts a representation session, then Alice revokes the grant
    session = create_representation_session_for(grant: grant, representative: @bob)
    grant.revoke!

    headers_with_revoked_grant = @headers.merge(
      "X-Representation-Session-ID" => session.id
    )

    get @superagent.path, headers: headers_with_revoked_grant

    # EXPECTED: Should return 403 Forbidden because grant is revoked
    # This will FAIL because the header is currently ignored
    assert_response :forbidden,
                    "API should reject representation when grant is revoked, " \
                    "but got #{response.status}"
  end

  test "FAILING: API rejects representation when token user is not the representative" do
    carol = create_user(email: "carol_#{SecureRandom.hex(4)}@example.com", name: "Carol")
    @tenant.add_user!(carol)
    @superagent.add_user!(carol)

    # Alice grants Bob (not Carol) permission
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "Bob acts for Alice",
      permissions: { "create_notes" => true },
    )
    grant.accept!

    # Bob starts a representation session
    session = create_representation_session_for(grant: grant, representative: @bob)

    # Create a token for Carol
    carol_token = ApiToken.create!(
      tenant: @tenant,
      user: carol,
      scopes: ApiToken.valid_scopes,
    )

    # Carol tries to use Bob's representation session (which she's not authorized for)
    carol_headers = {
      "Authorization" => "Bearer #{carol_token.plaintext_token}",
      "Accept" => "text/markdown",
      "X-Representation-Session-ID" => session.id,
    }

    get @superagent.path, headers: carol_headers

    # EXPECTED: Should return 403 Forbidden because Carol is not the session's representative
    # This will FAIL because the header is currently ignored
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

  test "FAILING: API rejects request when user has active session but header is missing" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "Bob acts for Alice",
      permissions: { "create_notes" => true },
    )
    grant.accept!

    # Bob starts a representation session
    session = create_representation_session_for(grant: grant, representative: @bob)

    # Bob makes an API call WITHOUT the X-Representation-Session-ID header
    # Even though the session exists, we're not passing it
    get @superagent.path, headers: @headers

    # EXPECTED: Should return 409 Conflict (or similar) with info about active session
    # This forces the API caller to be explicit about their intent
    # This will FAIL because the feature is not implemented
    assert_response :conflict,
                    "API should reject request when user has active representation session " \
                    "but X-Representation-Session-ID header is missing. Got #{response.status}"

    # The error response should include the active session ID so caller can fix their request
    body = response.body
    assert_includes body, session.id,
                    "Error response should include the active session ID"
  end

  # =========================================================================
  # REPRESENTATION SESSION ACTIVITY LOGGING
  # =========================================================================

  test "FAILING: API actions with representation are logged to the session" do
    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @alice,
      trusted_user: @bob,
      relationship_phrase: "Bob acts for Alice",
      permissions: { "create_notes" => true },
      studio_scope: { "mode" => "all" },
    )
    grant.accept!

    session = create_representation_session_for(grant: grant, representative: @bob)
    initial_action_count = session.action_count

    # Switch to the studio context
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)

    headers_with_representation = @headers.merge(
      "X-Representation-Session-ID" => session.id
    )

    # Create a note via API
    post "/note/actions/create_note",
         params: { title: "Logged Note", text: "This should be logged" },
         headers: headers_with_representation

    # EXPECTED: The action should be logged to the representation session
    # This will FAIL because API representation is not implemented
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

    get @superagent.path, headers: internal_headers
    assert_response :success

    # Currently acts as Bob
    assert_includes response.body, @bob.name
  end
end
