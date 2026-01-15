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
    @headers = {
      "Authorization" => "Bearer #{@api_token.token}",
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

  # Create (subagent users only)
  test "create creates a subagent user" do
    user_params = {
      name: "Subagent Test User",
      email: "subagent-#{SecureRandom.hex(4)}@example.com",
      handle: "subagent-#{SecureRandom.hex(4)}"
    }
    assert_difference "User.where(user_type: 'subagent').count", 1 do
      post api_path, params: user_params.to_json, headers: @headers
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "subagent", body["user_type"]
    assert_equal "Subagent Test User", body["display_name"]
  end

  test "create with generate_token returns token" do
    user_params = {
      name: "Subagent User with Token",
      email: "subagent-token-#{SecureRandom.hex(4)}@example.com",
      handle: "subagent-token-#{SecureRandom.hex(4)}",
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
      name: "Subagent User No Token",
      email: "subagent-notoken-#{SecureRandom.hex(4)}@example.com",
      handle: "subagent-notoken-#{SecureRandom.hex(4)}"
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

  test "update can update subagent user created by current user" do
    # Create a subagent user
    subagent = User.create!(
      email: "subagent-update-#{SecureRandom.hex(4)}@example.com",
      name: "Subagent for Update",
      user_type: "subagent",
      parent_id: @user.id
    )
    @tenant.add_user!(subagent)
    update_params = { display_name: "Updated Subagent Name" }
    put api_path("/#{subagent.id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    subagent.reload
    assert_equal "Updated Subagent Name", subagent.display_name
  end

  test "update cannot update other person user" do
    other_user = create_user(email: "other@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    update_params = { display_name: "Hacked Name" }
    put api_path("/#{other_user.id}"), params: update_params.to_json, headers: @headers
    assert_response :unauthorized
  end

  test "update can archive subagent user" do
    subagent = User.create!(
      email: "subagent-archive-#{SecureRandom.hex(4)}@example.com",
      name: "Subagent for Archive",
      user_type: "subagent",
      parent_id: @user.id
    )
    @tenant.add_user!(subagent)
    update_params = { archived: true }
    put api_path("/#{subagent.id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    # User#tenant_user is memoized, so we need to query fresh
    tenant_user = TenantUser.find_by(user_id: subagent.id, tenant_id: @tenant.id)
    assert tenant_user.archived_at.present?, "Subagent should be archived"
  end

  # Delete
  test "delete deletes subagent user with no data" do
        subagent = User.create!(
      email: "subagent-delete-#{SecureRandom.hex(4)}@example.com",
      name: "Subagent for Delete",
      user_type: "subagent",
      parent_id: @user.id
    )
    @tenant.add_user!(subagent)
    assert_difference "User.count", -1 do
      delete api_path("/#{subagent.id}"), headers: @headers
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
