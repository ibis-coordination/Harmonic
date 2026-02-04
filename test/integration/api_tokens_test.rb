require "test_helper"

class ApiTokensTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @superagent = @global_superagent
    @superagent.enable_api!
    @user = @global_user
    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    # Store plaintext token before it's lost (only available immediately after creation)
    @plaintext_token = @api_token.plaintext_token
    @headers = {
      "Authorization" => "Bearer #{@plaintext_token}",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def api_path(path = "")
    "/api/v1/users/#{@user.id}/tokens#{path}"
  end

  # Index
  test "index returns user's tokens" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    assert body.any? { |t| t["id"] == @api_token.id }
  end

  test "index returns obfuscated token values" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    token_data = body.find { |t| t["id"] == @api_token.id }
    assert token_data["token"].include?("*")
    assert_not_equal @plaintext_token, token_data["token"]
  end

  test "index includes token metadata" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    token_data = body.find { |t| t["id"] == @api_token.id }
    assert token_data.key?("name")
    assert token_data.key?("scopes")
    assert token_data.key?("active")
    assert token_data.key?("expires_at")
    assert token_data.key?("last_used_at")
  end

  # Show
  test "show returns a token" do
    get api_path("/#{@api_token.id}"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @api_token.id, body["id"]
  end

  test "show returns 404 for non-existent token" do
    get api_path("/nonexistent-uuid"), headers: @headers
    assert_response :not_found
  end

  test "show always returns obfuscated token (plaintext is only available on creation)" do
    # With hashed tokens, we can never retrieve the full plaintext after creation
    # because we only store the hash, not the plaintext
    get api_path("/#{@api_token.id}?include=full_token"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    # Should return obfuscated token even with include=full_token
    # because plaintext is not available after initial creation
    assert_includes body["token"], "*"
    assert_equal @api_token.obfuscated_token, body["token"]
  end

  test "create returns full plaintext token in response" do
    # When creating a token, the plaintext should be returned so user can save it
    token_params = {
      name: "Token to check plaintext",
      scopes: ["read:all"],
    }
    post api_path, params: token_params.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    # Token should be the full plaintext (40 chars for hex(20))
    assert_equal 40, body["token"].length
    assert_not_includes body["token"], "*"
  end

  # Create
  test "create creates a new token" do
    token_params = {
      name: "New API Token",
      scopes: ["read:all"],
      expires_at: (Time.current + 6.months).iso8601
    }
    assert_difference "ApiToken.count", 1 do
      post api_path, params: token_params.to_json, headers: @headers
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "New API Token", body["name"]
  end

  test "create with default expiration" do
    token_params = {
      name: "Token with Default Expiration",
      scopes: ["read:all"]
    }
    post api_path, params: token_params.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    # Should have an expiration date set (default 1 year)
    assert body["expires_at"].present?
  end

  test "create with custom scopes" do
    token_params = {
      name: "Read-Only Token",
      scopes: ["read:all"]
    }
    post api_path, params: token_params.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal ["read:all"], body["scopes"]
  end

  test "create with read-only token returns forbidden" do
    skip "Bug: api_tokens not recognized as valid resource for scope validation"
    @api_token.update!(scopes: ApiToken.read_scopes)
    token_params = { name: "Test", scopes: ["read:all"] }
    post api_path, params: token_params.to_json, headers: @headers
    assert_response :forbidden
  end

  # Update
  test "update returns 404 for non-existent token" do
    put api_path("/nonexistent-uuid"), params: { name: "Updated" }.to_json, headers: @headers
    assert_response :not_found
  end

  test "update by token string lookup returns 404 (security: token values should not be in URLs)" do
    # Create a second token to update
    token_to_update = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Token to Update",
      scopes: ["read:all"]
    )
    token_plaintext = token_to_update.plaintext_token
    # Trying to look up by token value should return 404
    put api_path("/#{token_plaintext}"), params: { name: "Updated" }.to_json, headers: @headers
    assert_response :not_found
    # But lookup by ID should work
    put api_path("/#{token_to_update.id}"), params: { name: "Updated" }.to_json, headers: @headers
    assert_response :success
  end

  test "update can change token name" do
    token_to_update = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Original Name",
      scopes: ["read:all"]
    )
    put api_path("/#{token_to_update.id}"), params: { name: "New Name" }.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "New Name", body["name"]
    token_to_update.reload
    assert_equal "New Name", token_to_update.name
  end

  # Delete
  test "delete deletes a token" do
    token_to_delete = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Token to Delete",
      scopes: ["read:all"]
    )
    delete api_path("/#{token_to_delete.id}"), headers: @headers
    assert_response :success
    token_to_delete.reload
    assert token_to_delete.deleted?
  end

  test "delete returns 404 for non-existent token" do
    delete api_path("/nonexistent-uuid"), headers: @headers
    assert_response :not_found
  end

  test "delete by token string lookup returns 404 (security: token values should not be in URLs)" do
    token_to_delete = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Token to Delete by String",
      scopes: ["read:all"]
    )
    token_plaintext = token_to_delete.plaintext_token
    # Trying to look up by token value should return 404
    delete api_path("/#{token_plaintext}"), headers: @headers
    assert_response :not_found
    # Token should NOT be deleted
    token_to_delete.reload
    assert_not token_to_delete.deleted?
    # But delete by ID should work
    delete api_path("/#{token_to_delete.id}"), headers: @headers
    assert_response :success
    token_to_delete.reload
    assert token_to_delete.deleted?
  end

  # Token scopes
  test "token with read scope can read but not write" do
    skip "Bug: api_tokens not recognized as valid resource for scope validation"
    read_only_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes
    )
    read_only_headers = @headers.merge("Authorization" => "Bearer #{read_only_token.plaintext_token}")

    # Can read
    get api_path, headers: read_only_headers
    assert_response :success

    # Cannot create
    token_params = { name: "New Token", scopes: ["read:all"] }
    post api_path, params: token_params.to_json, headers: read_only_headers
    assert_response :forbidden
  end

  # Token expiration
  test "expired token cannot be used" do
    expired_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
      expires_at: Time.current - 1.day
    )
    expired_headers = @headers.merge("Authorization" => "Bearer #{expired_token.plaintext_token}")
    get api_path, headers: expired_headers
    assert_response :unauthorized
  end

  # Token last_used_at tracking
  test "using token updates last_used_at" do
    initial_last_used = @api_token.last_used_at
    get api_path, headers: @headers
    assert_response :success
    @api_token.reload
    assert @api_token.last_used_at > initial_last_used if initial_last_used.present?
    assert @api_token.last_used_at.present?
  end

  # === Web UI Token Creation Security Tests ===
  # The web UI controller (ApiTokensController) has separate routes for token creation
  # that don't go through the V1 API. These tests ensure internal tokens can't be
  # created through those routes either.

  test "web UI form create ignores internal param" do
    sign_in_as(@user, tenant: @tenant)

    # Even if someone tries to inject internal: true via form params, it should be ignored
    token_params = {
      api_token: {
        name: "Attempted Internal Token",
        read_write: "read",
        internal: true,  # This should be ignored by strong params
      }
    }

    assert_difference "ApiToken.count", 1 do
      post "/u/#{@user.handle}/settings/tokens", params: token_params
    end

    # Find the newly created token
    created_token = ApiToken.order(created_at: :desc).first
    assert_not created_token.internal?, "Token should be external even though internal: true was passed"
  end

  test "markdown action create ignores internal param" do
    sign_in_as(@user, tenant: @tenant)

    # The markdown action endpoint also creates tokens
    action_params = {
      name: "Attempted Internal Token via Action",
      read_write: "read",
      internal: true,  # This should be ignored
    }

    assert_difference "ApiToken.count", 1 do
      post "/u/#{@user.handle}/settings/tokens/new/actions/create_api_token", params: action_params
    end

    # Find the newly created token
    created_token = ApiToken.order(created_at: :desc).first
    assert_not created_token.internal?, "Token should be external even though internal: true was passed"
  end
end
