require "test_helper"

class ApiUsersTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
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

  def api_path(path = "")
    "/api/v1/users#{path}"
  end

  # Index
  test "index returns tenant users" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    assert body.any? { |u| u["id"] == @user.id }
  end

  test "index includes user metadata" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    user_data = body.find { |u| u["id"] == @user.id }
    assert user_data.key?("email")
    assert user_data.key?("display_name")
    assert user_data.key?("handle")
    assert user_data.key?("user_type")
  end

  # Show
  test "show returns a user" do
    get api_path("/#{@user.id}"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @user.id, body["id"]
    assert_equal @user.email, body["email"]
  end

  test "show returns 404 for non-existent user" do
    get api_path("/nonexistent-uuid"), headers: @headers
    assert_response :not_found
  end

  # === v1 API is read-only — user writes happen via action routes ===
  # AI agent creation: /ai-agents/new/actions/create_ai_agent
  # User profile updates: /u/:handle/settings/actions/update_profile
  # User deletion: HTML resource route at /u/:handle (UI button)

  test "v1 users API has no write routes (read-only API)" do
    assert_raises(ActionController::RoutingError) do
      post api_path, params: { name: "x", email: "y@z.com" }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      put api_path("/#{@user.id}"), params: { display_name: "x" }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      delete api_path("/#{@user.id}"), headers: @headers
    end
  end
end
