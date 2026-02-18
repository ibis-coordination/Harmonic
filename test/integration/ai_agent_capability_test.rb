require "test_helper"

class AiAgentCapabilityTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @parent = @global_user
    @tenant.enable_feature_flag!("ai_agents")

    @ai_agent = create_ai_agent_for(@parent, "Capability Test AiAgent")

    # Create an API token for the ai_agent
    @token = ApiToken.create!(
      user: @ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
      expires_at: 1.year.from_now
    )

    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  private

  def create_ai_agent_for(parent, name)
    ai_agent = create_ai_agent(parent: parent, name: name)
    @tenant.add_user!(ai_agent)
    @collective.add_user!(ai_agent)
    ai_agent
  end

  def api_headers
    {
      "Authorization" => "Bearer #{@token.plaintext_token}",
      "Accept" => "text/markdown",
    }
  end

  # ====================
  # /whoami Capabilities Display
  # ====================

  test "whoami shows full capabilities when no restrictions" do
    @ai_agent.update!(agent_configuration: nil)

    get "/whoami", headers: api_headers

    assert_response :success
    assert_match "full capabilities", response.body
    refute_match "cannot perform", response.body
  end

  test "whoami shows restricted capabilities when configured" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note", "add_comment"] })

    get "/whoami", headers: api_headers

    assert_response :success
    assert_match "restricted your capabilities", response.body
    # The markdown uses **cannot** for bold
    assert response.body.include?("cannot")
    # Should list actions that are NOT in capabilities
    assert_match "`vote`", response.body
    assert_match "`create_decision`", response.body
  end

  # ====================
  # Action Execution - Capability Blocked
  # ====================

  test "ai_agent cannot execute action not in capabilities" do
    # Give ai_agent only create_note capability
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    # Send heartbeat first to establish studio context
    post "/studios/#{@collective.handle}/actions/send_heartbeat",
      headers: api_headers
    assert_response :success

    # Create a decision to vote on
    decision = create_decision(
      tenant: @tenant,
      collective: @collective,
      created_by: @parent,
      question: "Test Decision"
    )
    option = create_option(
      tenant: @tenant,
      collective: @collective,
      created_by: @parent,
      decision: decision,
      title: "Option 1"
    )

    # Try to vote (not in capabilities) - use full path with studio handle
    post "/studios/#{@collective.handle}/d/#{decision.truncated_id}/actions/vote",
      params: { votes: [{ option_title: option.title, accept: true, prefer: false }] },
      headers: api_headers

    assert_response :forbidden
    assert_match "capabilities do not include", response.body
    assert_match "vote", response.body
  end

  test "ai_agent can execute action in capabilities" do
    # Give ai_agent full capabilities
    @ai_agent.update!(agent_configuration: nil)

    # Send heartbeat first to ensure studio access
    post "/studios/#{@collective.handle}/actions/send_heartbeat",
      headers: api_headers
    assert_response :success

    # Create a note through the API
    post "/studios/#{@collective.handle}/note/actions/create_note",
      params: { text: "Test note from ai_agent" },
      headers: api_headers

    assert_response :success
    assert Note.exists?(text: "Test note from ai_agent", created_by: @ai_agent)
  end

  test "ai_agent can always execute infrastructure actions" do
    # Restrict capabilities to only create_note
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    # send_heartbeat is always allowed
    post "/studios/#{@collective.handle}/actions/send_heartbeat",
      headers: api_headers

    assert_response :success

    # search is always allowed
    get "/search?query=test", headers: api_headers

    assert_response :success
  end

  test "ai_agent cannot execute blocked actions even with no capability restrictions" do
    # No capability restrictions
    @ai_agent.update!(agent_configuration: nil)

    # Check that the capability check denies blocked actions
    refute CapabilityCheck.allowed?(@ai_agent, "create_studio")
    refute ActionAuthorization.authorized?("create_studio", @ai_agent, {})
  end

  # ====================
  # Capability Configuration via Settings
  # ====================

  test "parent can update ai_agent capabilities" do
    sign_in_as(@parent, tenant: @tenant)

    # Update capabilities via the profile form (POST not PATCH)
    post "/u/#{@ai_agent.handle}/settings/profile",
      params: {
        name: @ai_agent.name,
        capabilities: ["create_note", "add_comment", "vote"],
      }

    assert_response :redirect
    @ai_agent.reload
    assert_equal ["create_note", "add_comment", "vote"], @ai_agent.agent_configuration["capabilities"]
  end

  test "unchecking all capabilities blocks all grantable actions" do
    # Start with some capabilities
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    sign_in_as(@parent, tenant: @tenant)

    # Uncheck all capabilities (no capabilities param sent = empty array saved)
    post "/u/#{@ai_agent.handle}/settings/profile",
      params: {
        name: @ai_agent.name,
        # No capabilities param = all boxes unchecked = empty array
      }

    assert_response :redirect
    @ai_agent.reload
    # Empty array means no grantable actions allowed
    assert_equal [], @ai_agent.agent_configuration["capabilities"]
  end

  test "invalid capabilities are filtered out" do
    sign_in_as(@parent, tenant: @tenant)

    # Try to set invalid capabilities
    post "/u/#{@ai_agent.handle}/settings/profile",
      params: {
        name: @ai_agent.name,
        capabilities: ["create_note", "invalid_action", "create_studio"],
      }

    assert_response :redirect
    @ai_agent.reload
    # Only valid grantable action should be saved
    assert_equal ["create_note"], @ai_agent.agent_configuration["capabilities"]
  end

  # ====================
  # AiAgent with no config can do everything grantable
  # ====================

  test "ai_agent with no config can execute any grantable action" do
    @ai_agent.update!(agent_configuration: nil)

    # Send heartbeat first
    post "/studios/#{@collective.handle}/actions/send_heartbeat",
      headers: api_headers

    # Create a note
    post "/studios/#{@collective.handle}/note/actions/create_note",
      params: { text: "Test note" },
      headers: api_headers

    assert_response :success
  end

  # ====================
  # Legacy HTML Route Capability Blocking
  # ====================

  test "ai_agent cannot create note via legacy HTML route when not in capabilities" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["vote"] })

    # Try to create note via legacy HTML route (not /actions/)
    post "/studios/#{@collective.handle}/note",
      params: { title: "Test", text: "Test note" },
      headers: api_headers

    assert_response :forbidden
    assert_match "capabilities do not include", response.body
    assert_match "create_note", response.body
  end

  test "ai_agent can create note via legacy HTML route when in capabilities" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    # Send heartbeat first
    post "/studios/#{@collective.handle}/actions/send_heartbeat",
      headers: api_headers

    # Create note via legacy HTML route
    post "/studios/#{@collective.handle}/note",
      params: { title: "Test", text: "Test note via legacy route" },
      headers: api_headers

    assert_response :redirect
    assert Note.exists?(text: "Test note via legacy route", created_by: @ai_agent)
  end

  test "ai_agent cannot create decision via legacy HTML route when not in capabilities" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    post "/studios/#{@collective.handle}/decide",
      params: { question: "Test decision?" },
      headers: api_headers

    assert_response :forbidden
    assert_match "create_decision", response.body
  end

  test "ai_agent cannot create commitment via legacy HTML route when not in capabilities" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    post "/studios/#{@collective.handle}/commit",
      params: { title: "Test commitment" },
      headers: api_headers

    assert_response :forbidden
    assert_match "create_commitment", response.body
  end

  test "ai_agent cannot create studio via legacy HTML route" do
    # Even with no restrictions, create_studio is always blocked
    @ai_agent.update!(agent_configuration: nil)

    post "/studios",
      params: { name: "New Studio", handle: "new-studio-#{SecureRandom.hex(4)}" },
      headers: api_headers

    assert_response :forbidden
    assert_match "create_studio", response.body
  end

  # ====================
  # REST API v1 Route Capability Blocking
  # ====================

  test "ai_agent cannot create note via v1 API when not in capabilities" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["vote"] })

    post "/studios/#{@collective.handle}/api/v1/notes",
      params: { title: "Test", text: "Test note via API" },
      headers: api_headers.merge("Content-Type" => "application/json"),
      as: :json

    assert_response :forbidden
    assert_match "create_note", response.body
  end

  test "ai_agent can create note via v1 API when in capabilities" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    # Send heartbeat first
    post "/studios/#{@collective.handle}/actions/send_heartbeat",
      headers: api_headers

    post "/studios/#{@collective.handle}/api/v1/notes",
      params: { title: "Test", text: "Test note via v1 API" },
      headers: api_headers.merge("Content-Type" => "application/json"),
      as: :json

    assert_response :success
    assert Note.exists?(text: "Test note via v1 API", created_by: @ai_agent)
  end

  test "ai_agent cannot create decision via v1 API when not in capabilities" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    post "/studios/#{@collective.handle}/api/v1/decisions",
      params: { question: "Test decision?" },
      headers: api_headers.merge("Content-Type" => "application/json"),
      as: :json

    assert_response :forbidden
    assert_match "create_decision", response.body
  end

  test "ai_agent cannot vote via v1 API when not in capabilities" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    # Create a decision to vote on
    decision = create_decision(
      tenant: @tenant,
      collective: @collective,
      created_by: @parent,
      question: "Test Decision"
    )
    option = create_option(
      tenant: @tenant,
      collective: @collective,
      created_by: @parent,
      decision: decision,
      title: "Option 1"
    )
    participant = DecisionParticipant.find_or_create_by!(
      decision: decision,
      user: @ai_agent
    )

    post "/studios/#{@collective.handle}/api/v1/decisions/#{decision.id}/participants/#{participant.id}/votes",
      params: { option_id: option.id, accepted: true },
      headers: api_headers.merge("Content-Type" => "application/json"),
      as: :json

    assert_response :forbidden
    assert_match "vote", response.body
  end

  test "ai_agent cannot create studio via v1 API" do
    # Even with no restrictions, create_studio is always blocked
    @ai_agent.update!(agent_configuration: nil)

    post "/api/v1/studios",
      params: { name: "New Studio", handle: "new-studio-#{SecureRandom.hex(4)}" },
      headers: api_headers.merge("Content-Type" => "application/json"),
      as: :json

    assert_response :forbidden
    assert_match "create_studio", response.body
  end

  test "ai_agent cannot join commitment via v1 API when not in capabilities" do
    @ai_agent.update!(agent_configuration: { "capabilities" => ["create_note"] })

    commitment = create_commitment(
      tenant: @tenant,
      collective: @collective,
      created_by: @parent,
      title: "Test Commitment"
    )

    post "/studios/#{@collective.handle}/api/v1/commitments/#{commitment.id}/join",
      params: { committed: true },
      headers: api_headers.merge("Content-Type" => "application/json"),
      as: :json

    assert_response :forbidden
    assert_match "join_commitment", response.body
  end
end
