require "test_helper"

class ApiTokensTest < ActionDispatch::IntegrationTest
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

  test "index does not include the plaintext token field" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    token_data = body.find { |t| t["id"] == @api_token.id }
    assert_not token_data.key?("token"), "plaintext token field should be omitted from index responses"
  end

  test "index includes token_prefix for identification" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    token_data = body.find { |t| t["id"] == @api_token.id }
    assert_equal @api_token.token_prefix, token_data["token_prefix"]
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

  test "show does not return the plaintext token (only available on creation)" do
    # With hashed tokens, we can never retrieve the full plaintext after creation
    # because we only store the hash, not the plaintext
    get api_path("/#{@api_token.id}?include=full_token"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_not body.key?("token"), "plaintext token should not be returned after creation"
    assert_equal @api_token.token_prefix, body["token_prefix"]
  end

  # === v1 API is read-only ===
  # Token CRUD goes through the HTML controller at /u/:handle/settings/tokens/...
  # These sentinels assert the v1 routes don't accept writes. In production
  # missing routes return 404; in tests they raise ActionController::RoutingError.

  test "POST to /api/v1/users/:user_id/tokens has no route (v1 is read-only)" do
    assert_raises(ActionController::RoutingError) do
      post api_path, params: { name: "should not work" }.to_json, headers: @headers
    end
  end

  test "PATCH to /api/v1/users/:user_id/tokens/:id has no route (v1 is read-only)" do
    assert_raises(ActionController::RoutingError) do
      patch api_path("/#{@api_token.id}"), params: { name: "should not work" }.to_json, headers: @headers
    end
  end

  test "DELETE to /api/v1/users/:user_id/tokens/:id has no route (v1 is read-only)" do
    assert_raises(ActionController::RoutingError) do
      delete api_path("/#{@api_token.id}"), headers: @headers
    end
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
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user.handle}/settings/tokens", method: :post)

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
    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{@user.handle}/settings/tokens", method: :post)

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

  # === Authorization Tests ===

  test "user cannot create token for another human user" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)

    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "ApiToken.count" do
      post "/u/#{other_user.handle}/settings/tokens", params: {
        api_token: { name: "Attempted Token", read_write: "read" },
      }
    end

    assert_response :forbidden
  end

  test "user cannot create token for another user's AI agent" do
    other_user = create_user(name: "Other Parent")
    @tenant.add_user!(other_user)
    # External mode so the agent can have tokens; mode is immutable after
    # creation, so set it at create time.
    other_ai_agent = create_ai_agent(parent: other_user, name: "Other Agent",
                                     agent_configuration: { "mode" => "external" })
    @tenant.add_user!(other_ai_agent)

    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "ApiToken.count" do
      post "/u/#{other_ai_agent.handle}/settings/tokens", params: {
        api_token: { name: "Attempted Token", read_write: "read" },
      }
    end

    assert_response :forbidden
  end

  test "parent can create token for their own AI agent" do
    # External mode so the agent can have tokens; mode is immutable after
    # creation, so set it at create time.
    ai_agent = create_ai_agent(parent: @user, name: "My Agent",
                               agent_configuration: { "mode" => "external" })
    @tenant.add_user!(ai_agent)

    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{ai_agent.handle}/settings/tokens", method: :post)

    assert_difference "ApiToken.count", 1 do
      post "/u/#{ai_agent.handle}/settings/tokens", params: {
        api_token: { name: "Agent Token", read_write: "read" },
      }
    end

    # Token should be associated with the AI agent, not the parent
    created_token = ApiToken.order(created_at: :desc).first
    assert_equal ai_agent.id, created_token.user_id
  end

  test "cannot create token for internal AI agent" do
    ai_agent = create_ai_agent(parent: @user, name: "Internal Agent")
    @tenant.add_user!(ai_agent)
    # Keep it internal (default)
    ai_agent.agent_configuration = { "mode" => "internal" }
    ai_agent.save!

    sign_in_with_reverification(@user, tenant: @tenant, path: "/u/#{ai_agent.handle}/settings/tokens", method: :post)

    assert_no_difference "ApiToken.count" do
      post "/u/#{ai_agent.handle}/settings/tokens", params: {
        api_token: { name: "Attempted Token", read_write: "read" },
      }
    end

    assert_response :forbidden
  end
end
