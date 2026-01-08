require "test_helper"

class ApiTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @studio = @global_studio
    @studio.enable_api!
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

  def v1_api_base_path
    "#{@studio.path}/api/v1"
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
    @headers["Authorization"] = "Bearer #{@api_token.token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access with deleted API token" do
    @api_token.update!(deleted_at: Time.current)
    @headers["Authorization"] = "Bearer #{@api_token.token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "allows write access with write scope" do
    @api_token.update!(scopes: ApiToken.valid_scopes)
    @headers["Authorization"] = "Bearer #{@api_token.token}"
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
    @headers["Authorization"] = "Bearer #{@api_token.token}"
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
    @tenant.settings['api_enabled'] = false
    @tenant.save!

    get v1_api_endpoint, headers: @headers
    assert_response :forbidden
    assert_match /API not enabled/, JSON.parse(response.body)["error"]
  end

  test "denies access when API is disabled at studio level" do
    # Create a non-main studio since main studios always have API enabled
    non_main_studio = Studio.create!(
      name: "Test Studio",
      handle: "test-studio-#{SecureRandom.hex(4)}",
      tenant: @tenant,
      studio_type: "studio",
      created_by: @user,
      updated_by: @user
    )
    non_main_studio.enable_api!

    # Use the non-main studio's API endpoint
    non_main_api_endpoint = "#{non_main_studio.path}/api/v1/cycles"

    # Verify it works when enabled
    get non_main_api_endpoint, headers: @headers
    assert_response :success

    # Now disable and verify it fails
    non_main_studio.settings['api_enabled'] = false
    non_main_studio.settings['feature_flags'] = { 'api' => false }
    non_main_studio.save!

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

    # Both tokens should work
    @headers["Authorization"] = "Bearer #{@api_token.token}"
    get v1_api_endpoint, headers: @headers
    assert_response :success

    @headers["Authorization"] = "Bearer #{token2.token}"
    get v1_api_endpoint, headers: @headers
    assert_response :success
  end

  test "deleting one token does not affect other tokens" do
    token2 = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )

    # Delete the first token
    @api_token.update!(deleted_at: Time.current)

    # First token should fail
    @headers["Authorization"] = "Bearer #{@api_token.token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized

    # Second token should still work
    @headers["Authorization"] = "Bearer #{token2.token}"
    get v1_api_endpoint, headers: @headers
    assert_response :success
  end
end