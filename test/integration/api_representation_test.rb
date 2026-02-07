# typed: false

require "test_helper"

# Tests for API representation - these tests FAIL to expose the gap in implementation.
# See ApplicationController#resolve_api_user: "TODO: Handle representation through the API"
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

  # =========================================================================
  # FAILING TESTS: API REPRESENTATION NOT YET IMPLEMENTED
  # These tests assert expected behavior. They will FAIL until the feature is built.
  # =========================================================================

  test "FAILING: API caller can represent via X-Represent-As header with valid trustee" do
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

    trustee_user = grant.trustee_user

    # Bob specifies representation via header
    headers_with_representation = @headers.merge(
      "X-Represent-As" => trustee_user.id
    )

    get @superagent.path, headers: headers_with_representation
    assert_response :success

    # EXPECTED: The response should indicate Bob is acting as a trustee for Alice
    # This will FAIL because the feature is not implemented
    assert_includes response.body, "acting on behalf of",
                    "API representation via X-Represent-As header is not implemented"
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

    trustee_user = grant.trustee_user

    # Switch to the studio context for the API call
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)

    # Bob creates a note via API while representing Alice
    headers_with_representation = @headers.merge(
      "X-Represent-As" => trustee_user.id
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
    assert_equal trustee_user, note.created_by,
                 "Note should be attributed to trustee_user when X-Represent-As header is set, " \
                 "but was attributed to #{note.created_by.name} (#{note.created_by.user_type})"
  end

  test "FAILING: API rejects representation with invalid trustee user ID" do
    fake_trustee_id = SecureRandom.uuid

    headers_with_fake_rep = @headers.merge(
      "X-Represent-As" => fake_trustee_id
    )

    get @superagent.path, headers: headers_with_fake_rep

    # EXPECTED: Should return 403 Forbidden when trustee_user_id is invalid
    # This will FAIL because the header is currently ignored
    assert_response :forbidden,
                    "API should reject representation with invalid trustee_user_id, " \
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
    grant.revoke!

    trustee_user = grant.trustee_user

    headers_with_revoked = @headers.merge(
      "X-Represent-As" => trustee_user.id
    )

    get @superagent.path, headers: headers_with_revoked

    # EXPECTED: Should return 403 Forbidden because grant is revoked
    # This will FAIL because the header is currently ignored
    assert_response :forbidden,
                    "API should reject representation when grant is revoked, " \
                    "but got #{response.status}"
  end

  test "FAILING: API rejects representation when token user is not the trusted_user" do
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

    # Create a token for Carol
    carol_token = ApiToken.create!(
      tenant: @tenant,
      user: carol,
      scopes: ApiToken.valid_scopes,
    )

    # Carol tries to represent using Bob's trustee (which she's not authorized for)
    carol_headers = {
      "Authorization" => "Bearer #{carol_token.plaintext_token}",
      "Accept" => "text/markdown",
      "X-Represent-As" => grant.trustee_user.id,
    }

    get @superagent.path, headers: carol_headers

    # EXPECTED: Should return 403 Forbidden because Carol is not the trusted_user
    # This will FAIL because the header is currently ignored
    assert_response :forbidden,
                    "API should reject representation when token user is not the trusted_user, " \
                    "but got #{response.status}"
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
