require "test_helper"

class ApiTest < ActionDispatch::IntegrationTest
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
    @plaintext_token = @api_token.plaintext_token
    @headers = {
      "Authorization" => "Bearer #{@plaintext_token}",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def v1_api_base_path
    "#{@superagent.path}/api/v1"
  end

  def v1_api_endpoint
    "#{v1_api_base_path}/cycles"
  end

  test "allows access with valid API token" do
    get v1_api_endpoint, headers: @headers
    assert_response :success
  end

  test "denies access with invalid API token" do
    @headers["Authorization"] = "Bearer invalid_token"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access without API token" do
    @headers.delete("Authorization")
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access with expired API token" do
    @api_token.update!(expires_at: Time.current - 1.day)
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access with deleted API token" do
    @api_token.update!(deleted_at: Time.current)
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "allows write access with write scope" do
    @api_token.update!(scopes: ApiToken.valid_scopes)
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    note_params = {
      title: "Test Note",
      text: "This is a test note.",
      deadline: Time.current + 1.week
    }
    post "#{v1_api_base_path}/notes", params: note_params.to_json, headers: @headers
    assert_response :success
    assert_equal "Test Note", JSON.parse(response.body)["title"]
  end

  test "denies write access with read-only scope" do
    @api_token.update!(scopes: ApiToken.read_scopes)
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    note_params = {
      title: "Test Note",
      text: "This is a test note.",
      deadline: Time.current + 1.week
    }
    post "#{v1_api_base_path}/notes", params: note_params.to_json, headers: @headers
    assert_response :forbidden
  end

  # === API Enabled/Disabled Tests ===

  test "denies access when API is disabled at tenant level" do
    @tenant.set_feature_flag!("api", false)

    get v1_api_endpoint, headers: @headers
    assert_response :forbidden
    assert_match /API not enabled/, JSON.parse(response.body)["error"]
  end

  test "denies access when API is disabled at studio level" do
    # Create a non-main studio since main studios always have API enabled
    non_main_superagent = Superagent.create!(
      name: "Test Studio",
      handle: "test-studio-#{SecureRandom.hex(4)}",
      tenant: @tenant,
      superagent_type: "studio",
      created_by: @user,
      updated_by: @user
    )
    non_main_superagent.enable_api!

    # Use the non-main studio's API endpoint
    non_main_api_endpoint = "#{non_main_superagent.path}/api/v1/cycles"

    # Verify it works when enabled
    get non_main_api_endpoint, headers: @headers
    assert_response :success

    # Now disable and verify it fails
    non_main_superagent.settings['api_enabled'] = false
    non_main_superagent.settings['feature_flags'] = { 'api' => false }
    non_main_superagent.save!

    get non_main_api_endpoint, headers: @headers
    assert_response :forbidden
    assert_match /API not enabled/, JSON.parse(response.body)["error"]
  end

  test "allows access when API is re-enabled" do
    # Disable then re-enable
    @tenant.settings['api_enabled'] = false
    @tenant.save!
    @tenant.enable_api!

    get v1_api_endpoint, headers: @headers
    assert_response :success
  end

  # === Internal Token Bypass Tests ===

  test "internal token bypasses studio-level API check" do
    # Create a non-main studio with API disabled
    non_main_superagent = Superagent.create!(
      name: "Internal Test Studio",
      handle: "internal-test-#{SecureRandom.hex(4)}",
      tenant: @tenant,
      superagent_type: "studio",
      created_by: @user,
      updated_by: @user
    )
    # Ensure API is disabled
    non_main_superagent.settings['api_enabled'] = false
    non_main_superagent.settings['feature_flags'] = { 'api' => false }
    non_main_superagent.save!

    # Create internal token
    internal_token = ApiToken.create_internal_token(user: @user, tenant: @tenant)
    internal_headers = {
      "Authorization" => "Bearer #{internal_token.plaintext_token}",
      "Content-Type" => "application/json",
    }

    # Internal token should bypass the studio API check
    non_main_api_endpoint = "#{non_main_superagent.path}/api/v1/cycles"
    get non_main_api_endpoint, headers: internal_headers
    assert_response :success
  end

  test "internal token bypasses tenant-level API check" do
    # Disable API at tenant level
    @tenant.set_feature_flag!("api", false)

    # Create internal token
    internal_token = ApiToken.create_internal_token(user: @user, tenant: @tenant)
    internal_headers = {
      "Authorization" => "Bearer #{internal_token.plaintext_token}",
      "Content-Type" => "application/json",
    }

    # Internal token should bypass the tenant API check
    get v1_api_endpoint, headers: internal_headers
    assert_response :success
  end

  test "external token still blocked when API disabled" do
    # Disable API at tenant level
    @tenant.set_feature_flag!("api", false)

    # External token should still be blocked
    get v1_api_endpoint, headers: @headers
    assert_response :forbidden
    assert_match /API not enabled/, JSON.parse(response.body)["error"]
  end

  test "API ignores internal param when creating tokens" do
    # The V1 API only passes whitelisted params (name, scopes, expires_at)
    # The internal param should be ignored, resulting in an external token
    token_params = {
      name: "Attempted Internal Token",
      scopes: ApiToken.read_scopes,
      expires_at: 1.year.from_now,
      internal: true,  # This should be ignored
    }

    post "/api/v1/users/#{@user.id}/tokens", params: token_params.to_json, headers: @headers
    assert_response :success

    # The created token should NOT be internal - the param was ignored
    response_data = JSON.parse(response.body)
    created_token = ApiToken.find(response_data["id"])
    assert_not created_token.internal?, "Token should be external even though internal: true was passed"
  end

  # === Token Scope Edge Cases ===

  test "token with empty scopes cannot be created" do
    assert_raises ActiveRecord::RecordInvalid do
      ApiToken.create!(
        tenant: @tenant,
        user: @user,
        scopes: []
      )
    end
  end

  test "token with invalid scopes cannot be created" do
    assert_raises ActiveRecord::RecordInvalid do
      @api_token.update!(scopes: ["READ:all"])  # Wrong case
    end
  end

  # === Multiple Token Tests ===

  test "user can have multiple active tokens" do
    token2 = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    token2_plaintext = token2.plaintext_token

    # Both tokens should work
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    get v1_api_endpoint, headers: @headers
    assert_response :success

    @headers["Authorization"] = "Bearer #{token2_plaintext}"
    get v1_api_endpoint, headers: @headers
    assert_response :success
  end

  test "deleting one token does not affect other tokens" do
    token2 = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    token2_plaintext = token2.plaintext_token

    # Delete the first token
    @api_token.update!(deleted_at: Time.current)

    # First token should fail
    @headers["Authorization"] = "Bearer #{@plaintext_token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized

    # Second token should still work
    @headers["Authorization"] = "Bearer #{token2_plaintext}"
    get v1_api_endpoint, headers: @headers
    assert_response :success
  end
end