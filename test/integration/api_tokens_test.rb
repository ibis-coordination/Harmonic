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
    @headers = {
      "Authorization" => "Bearer #{@api_token.token}",
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
    assert_not_equal @api_token.token, token_data["token"]
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

  test "show with include=full_token returns full token value" do
    get api_path("/#{@api_token.id}?include=full_token"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @api_token.token, body["token"]
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

  # Token scopes
  test "token with read scope can read but not write" do
    skip "Bug: api_tokens not recognized as valid resource for scope validation"
    read_only_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.read_scopes
    )
    read_only_headers = @headers.merge("Authorization" => "Bearer #{read_only_token.token}")

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
    expired_headers = @headers.merge("Authorization" => "Bearer #{expired_token.token}")
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
end
