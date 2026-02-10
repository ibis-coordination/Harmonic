require "test_helper"

class ApiUsersTest < ActionDispatch::IntegrationTest
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

  # Create (ai_agent users only)
  test "create creates a ai_agent user" do
    user_params = {
      name: "AiAgent Test User",
      email: "ai_agent-#{SecureRandom.hex(4)}@example.com",
      handle: "ai_agent-#{SecureRandom.hex(4)}"
    }
    assert_difference "User.where(user_type: 'ai_agent').count", 1 do
      post api_path, params: user_params.to_json, headers: @headers
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "ai_agent", body["user_type"]
    assert_equal "AiAgent Test User", body["display_name"]
  end

  test "create with generate_token returns token" do
    user_params = {
      name: "AiAgent User with Token",
      email: "ai_agent-token-#{SecureRandom.hex(4)}@example.com",
      handle: "ai_agent-token-#{SecureRandom.hex(4)}",
      generate_token: true
    }
    post api_path, params: user_params.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("token")
    assert body["token"].present?
  end

  test "create without generate_token does not return token" do
    user_params = {
      name: "AiAgent User No Token",
      email: "ai_agent-notoken-#{SecureRandom.hex(4)}@example.com",
      handle: "ai_agent-notoken-#{SecureRandom.hex(4)}"
    }
    post api_path, params: user_params.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_not body.key?("token")
  end

  test "create with read-only token returns forbidden" do
    @api_token.update!(scopes: ApiToken.read_scopes)
    user_params = {
      name: "Test",
      email: "test-#{SecureRandom.hex(4)}@example.com"
    }
    post api_path, params: user_params.to_json, headers: @headers
    assert_response :forbidden
  end

  # Update
  # Note: Controller only allows updating display_name and handle, not name
  # (name comes from OAuth and shouldn't be user-editable for person users)
  test "update updates own user record" do
    update_params = { display_name: "Updated Display Name" }
    put api_path("/#{@user.id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    @user.reload
    assert_equal "Updated Display Name", @user.display_name
  end

  test "update can update ai_agent user created by current user" do
    # Create a ai_agent user
    ai_agent = create_ai_agent(parent: @user, name: "AiAgent for Update")
    @tenant.add_user!(ai_agent)
    update_params = { display_name: "Updated AiAgent Name" }
    put api_path("/#{ai_agent.id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    ai_agent.reload
    assert_equal "Updated AiAgent Name", ai_agent.display_name
  end

  test "update cannot update other person user" do
    other_user = create_user(email: "other@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    update_params = { display_name: "Hacked Name" }
    put api_path("/#{other_user.id}"), params: update_params.to_json, headers: @headers
    assert_response :unauthorized
  end

  test "update can archive ai_agent user" do
    ai_agent = create_ai_agent(parent: @user, name: "AiAgent for Archive")
    @tenant.add_user!(ai_agent)
    update_params = { archived: true }
    put api_path("/#{ai_agent.id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    # User#tenant_user is memoized, so we need to query fresh
    tenant_user = TenantUser.find_by(user_id: ai_agent.id, tenant_id: @tenant.id)
    assert tenant_user.archived_at.present?, "AiAgent should be archived"
  end

  # Delete
  test "delete deletes ai_agent user with no data" do
    ai_agent = create_ai_agent(parent: @user, name: "AiAgent for Delete")
    @tenant.add_user!(ai_agent)
    assert_difference "User.count", -1 do
      delete api_path("/#{ai_agent.id}"), headers: @headers
    end
    assert_response :success
  end

  test "delete returns 404 for non-existent user" do
        delete api_path("/nonexistent-uuid"), headers: @headers
    assert_response :not_found
  end

  test "delete returns unauthorized for other person user" do
        other_user = create_user(email: "other@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    delete api_path("/#{other_user.id}"), headers: @headers
    assert_response :unauthorized
  end
end
