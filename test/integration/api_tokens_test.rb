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
    @api_token.update!(scopes: ApiToken.read_scopes)
    token_params = { name: "Test", scopes: ["read:all"] }
    post api_path, params: token_params.to_json, headers: @headers
    assert_response :forbidden
  end

  test "external AI agent cannot create a token via the v1 API" do
    # Blocked twice: by the capability system (create_api_token isn't a
    # grantable action for agents) and by the controller's human-only check
    # added as defense in depth. We only assert the result, not which layer
    # rejected the request.
    agent = create_ai_agent(
      parent: @user,
      name: "ApiCreator",
      agent_configuration: { "mode" => "external" },
    )
    @tenant.add_user!(agent)
    agent_token = ApiToken.create!(
      tenant: @tenant,
      user: agent,
      name: "Agent's token",
      scopes: ApiToken.valid_scopes,
    )
    agent_headers = {
      "Authorization" => "Bearer #{agent_token.plaintext_token}",
      "Content-Type" => "application/json",
    }
    post "/api/v1/users/#{agent.id}/tokens",
      params: { name: "Agent-minted", scopes: ["read:all"] }.to_json, headers: agent_headers
    assert_response :forbidden
  end

  test "create rejects when user is at the active token cap" do
    # Fill to the cap (setup already creates 1; create MAX-1 more)
    (ApiToken::MAX_ACTIVE_TOKENS_PER_USER - 1).times do |i|
      ApiToken.create!(tenant: @tenant, user: @user, name: "Filler #{i}", scopes: ["read:all"])
    end

    token_params = { name: "Over Cap", scopes: ["read:all"] }
    post api_path, params: token_params.to_json, headers: @headers
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_match(/maximum.*active.*token|cap|limit/i, body["error"])
  end

  test "create allows new tokens after deleting old ones below the cap" do
    fillers = (ApiToken::MAX_ACTIVE_TOKENS_PER_USER - 1).times.map do |i|
      ApiToken.create!(tenant: @tenant, user: @user, name: "Filler #{i}", scopes: ["read:all"])
    end
    # At the cap — next create should fail
    post api_path, params: { name: "Over", scopes: ["read:all"] }.to_json, headers: @headers
    assert_response :bad_request

    # Soft-delete one filler — should now have room
    fillers.first.delete!
    post api_path, params: { name: "Below cap", scopes: ["read:all"] }.to_json, headers: @headers
    assert_response :success
  end

  test "create cap does not count expired tokens" do
    (ApiToken::MAX_ACTIVE_TOKENS_PER_USER - 1).times do |i|
      ApiToken.create!(tenant: @tenant, user: @user, name: "Filler #{i}", scopes: ["read:all"], expires_at: 1.day.ago)
    end
    post api_path, params: { name: "Fresh", scopes: ["read:all"] }.to_json, headers: @headers
    assert_response :success
  end

  test "create cannot grant scopes the creating token does not have" do
    # Token can create api_tokens and read notes, but cannot delete anything.
    @api_token.update!(scopes: ["create:api_tokens", "read:notes"])
    token_params = { name: "Escalation Attempt", scopes: ["delete:all"] }
    post api_path, params: token_params.to_json, headers: @headers
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_match(/scope/i, body["error"])
  end

  test "create cannot grant *:all when creating token only has a narrow scope for that action" do
    @api_token.update!(scopes: ["create:api_tokens", "read:notes"])
    token_params = { name: "Read All Attempt", scopes: ["read:all"] }
    post api_path, params: token_params.to_json, headers: @headers
    assert_response :forbidden
  end

  test "create can grant a scope when the creating token has the *:all wildcard for that action" do
    @api_token.update!(scopes: ["create:all"])
    token_params = { name: "Narrower Token", scopes: ["create:notes"] }
    post api_path, params: token_params.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal ["create:notes"], body["scopes"]
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

  test "update rejects changes to expires_at (tokens are immutable except for name)" do
    target = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Target",
      scopes: ["read:all"],
      expires_at: 1.month.from_now,
    )
    original_expires_at = target.expires_at
    put api_path("/#{target.id}"), params: { expires_at: 10.years.from_now }.to_json, headers: @headers
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_match(/immutable|cannot.*change|create a new token/i, body["error"])
    target.reload
    assert_in_delta original_expires_at, target.expires_at, 1.second
  end

  test "update rejects changes to scopes (tokens are immutable except for name)" do
    target = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      name: "Target",
      scopes: ["read:notes"]
    )
    put api_path("/#{target.id}"), params: { scopes: ["create:notes"] }.to_json, headers: @headers
    assert_response :bad_request
    target.reload
    assert_equal ["read:notes"], target.scopes
  end

  test "ai agent cannot update its own token" do
    agent = create_ai_agent(parent: @user, name: "Helper", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    # Give the agent's token broad scopes so the AI-agent block fires, not the scope check
    agent_token = ApiToken.create!(
      tenant: @tenant,
      user: agent,
      name: "Agent's token",
      scopes: ApiToken.valid_scopes,
    )
    agent_headers = {
      "Authorization" => "Bearer #{agent_token.plaintext_token}",
      "Content-Type" => "application/json",
    }
    put "/api/v1/users/#{agent.id}/tokens/#{agent_token.id}",
      params: { name: "Renamed by agent" }.to_json, headers: agent_headers
    assert_response :forbidden
    agent_token.reload
    assert_equal "Agent's token", agent_token.name
  end

  test "ai agent cannot delete its own token" do
    agent = create_ai_agent(parent: @user, name: "Helper2", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    agent_token = ApiToken.create!(
      tenant: @tenant,
      user: agent,
      name: "Agent's token",
      scopes: ApiToken.valid_scopes,
    )
    agent_headers = {
      "Authorization" => "Bearer #{agent_token.plaintext_token}",
      "Content-Type" => "application/json",
    }
    delete "/api/v1/users/#{agent.id}/tokens/#{agent_token.id}", headers: agent_headers
    assert_response :forbidden
    agent_token.reload
    assert_not agent_token.deleted?
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
    other_ai_agent = create_ai_agent(parent: other_user, name: "Other Agent")
    @tenant.add_user!(other_ai_agent)
    # Make it external so it can have tokens
    other_ai_agent.agent_configuration = { "mode" => "external" }
    other_ai_agent.save!

    sign_in_as(@user, tenant: @tenant)

    assert_no_difference "ApiToken.count" do
      post "/u/#{other_ai_agent.handle}/settings/tokens", params: {
        api_token: { name: "Attempted Token", read_write: "read" },
      }
    end

    assert_response :forbidden
  end

  test "parent can create token for their own AI agent" do
    ai_agent = create_ai_agent(parent: @user, name: "My Agent")
    @tenant.add_user!(ai_agent)
    # Make it external so it can have tokens
    ai_agent.agent_configuration = { "mode" => "external" }
    ai_agent.save!

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
