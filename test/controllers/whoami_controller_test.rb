require "test_helper"

class WhoamiControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # === Index (GET /whoami) HTML Tests ===

  test "unauthenticated user can access whoami page" do
    @tenant.settings["require_login"] = false
    @tenant.save!

    get "/whoami"
    assert_response :success
    assert_includes response.body, "Who Am I"
    assert_includes response.body, "Not Logged In"
  end

  test "authenticated user can access whoami page and sees their info" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami"
    assert_response :success
    assert_includes response.body, "Who Am I"
    assert_includes response.body, @user.display_name
    assert_includes response.body, @user.handle
  end

  test "whoami page shows tenant subdomain in profile URL" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami"
    assert_response :success
    assert_includes response.body, @tenant.subdomain
  end

  test "whoami page shows user collectives section" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami"
    assert_response :success
    assert_includes response.body, "Your Collectives"
  end

  # === Index (GET /whoami) Markdown Tests ===

  test "whoami responds to markdown format" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Who Am I"
    assert_includes response.body, @user.display_name
  end

  test "markdown whoami shows user info" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, @user.display_name
    assert_includes response.body, @user.handle
    assert_includes response.body, "logged in as"
  end

  test "unauthenticated markdown whoami shows not logged in message" do
    @tenant.settings["require_login"] = false
    @tenant.save!

    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "## Not Logged In"
  end

  test "markdown whoami without an active rep session shows no representation block" do
    # The rep block is gated by `if @current_representation_session`, so a
    # self-acting caller should never see "currently representing" or any
    # empty parenthetical from the rep template.
    sign_in_as(@user, tenant: @tenant)
    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_not_includes response.body, "currently representing"
    assert_not_includes response.body, "You ()"
    assert_not_includes response.body, "## Representation Session"
  end

  test "markdown whoami via API token without rep headers shows no representation block" do
    # Same as above but via API/MCP auth path. Stage 2 surfaced that the
    # rep block previously rendered "()" for API callers; verify the
    # block doesn't render at all when no rep is declared.
    @tenant.enable_api!
    @collective.enable_api!
    token = ApiToken.create!(tenant: @tenant, user: @user, scopes: ApiToken.valid_scopes)

    get "/whoami", headers: {
      "Authorization" => "Bearer #{token.plaintext_token}",
      "Accept" => "text/markdown",
    }
    assert_response :success
    assert_not_includes response.body, "currently representing"
    assert_not_includes response.body, "You ()"
    assert_not_includes response.body, "## Representation Session"
  end

  test "markdown whoami names the representative when an API caller is under rep" do
    # The "You (X) are currently representing Y" line in the rep banner
    # must surface the *representative's* display name (the agent/trustee
    # who is acting), not @current_human_user (which is only set on the
    # browser-session auth path and is nil for API/MCP callers under rep).
    @tenant.enable_api!
    @collective.enable_api!
    other_user = create_user(email: "rep-target-#{SecureRandom.hex(4)}@example.com", name: "Represented Target")
    @tenant.add_user!(other_user)
    mark_activated!(other_user)
    grant = TrusteeGrant.create!(
      tenant: @tenant, granting_user: other_user, trustee_user: @user,
      permissions: nil, collective_scope: { "mode" => "all" },
    )
    grant.accept!
    rep_session = RepresentationSession.create!(
      tenant: @tenant, representative_user: @user, trustee_grant: grant,
      confirmed_understanding: true, began_at: Time.current,
    )
    token = ApiToken.create!(tenant: @tenant, user: @user, scopes: ApiToken.valid_scopes)

    get "/whoami", headers: {
      "Authorization" => "Bearer #{token.plaintext_token}",
      "Accept" => "text/markdown",
      "X-Representation-Session-ID" => rep_session.id,
      "X-Representing-User" => other_user.handle,
    }
    assert_response :success
    assert_includes response.body, "You (#{@user.display_name}) are currently representing"
    assert_not_includes response.body, "You ()"
  end

  # === AiAgent User Tests ===

  test "whoami shows ai_agent parent info" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(ai_agent)

    # Create API token for ai_agent
    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users],
    )

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.plaintext_token}",
    }
    assert_response :success
    assert_includes response.body, "managed by"
    assert_includes response.body, @user.display_name
  end

  test "whoami shows ai_agent identity prompt when set" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test Assistant", agent_configuration: { "mode" => "external" })
    ai_agent.update_columns(agent_configuration: { "identity_prompt" => "You are a helpful assistant for scheduling meetings." })
    @tenant.add_user!(ai_agent)

    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users],
    )

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.plaintext_token}",
    }
    assert_response :success
    assert_includes response.body, "Identity Prompt"
    assert_includes response.body, "You are a helpful assistant for scheduling meetings."
  end

  test "whoami shows the persona identity prompt for the system agent (no parent)" do
    @tenant.enable_api!
    trio = PersonaSeeder.ensure_for(T.must(@tenant.main_collective), Personas::CADENCE)

    # System agents can't hold user-issued keys; they act via system-minted
    # internal tokens (this mirrors the automation path).
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: trio, initiated_by: @user,
      task: "whoami test", max_steps: 5, status: "queued"
    )
    api_token = ApiToken.create_internal_token(
      user: trio, tenant: @tenant, context: task_run
    )

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.plaintext_token}",
    }

    assert_response :success
    # The Identity Prompt section must render for system agents even though
    # they have no parent user — earlier the wrapping conditional silently
    # skipped Motto/IdentityPrompt/Capabilities for parent-less agents.
    assert_includes response.body, "## Identity Prompt"
    # Lead sentence should be the system-agent variant, not the parent-name one.
    assert_includes response.body, "built-in Harmonic system agent"
    # Actual prompt content (a stable fragment of cadence's persona prompt).
    assert_includes response.body, "You are Cadence"
  end

  test "whoami does not show identity prompt section when not set" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(ai_agent)

    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users],
    )

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.plaintext_token}",
    }
    assert_response :success
    assert_not_includes response.body, "Identity Prompt"
  end

  # === Scheduled Reminders Tests ===

  test "whoami shows upcoming reminders section" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
    notification = ReminderService.create!(user: @user, title: "Upcoming reminder", scheduled_for: 1.day.from_now)
    Note.create!(
      tenant: @tenant, collective: @collective, created_by: @user, updated_by: @user,
      text: "Upcoming reminder", subtype: "reminder",
      reminder_notification_id: notification.id, reminder_scheduled_for: 1.day.from_now,
    )
    Collective.clear_thread_scope

    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Upcoming Reminders"
    assert_includes response.body, "Upcoming reminder"
  end

  test "whoami does not show reminders section when empty" do
    sign_in_as(@user, tenant: @tenant)

    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_not_includes response.body, "Upcoming Reminders"
  end

  test "whoami shows link to notifications page" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
    notification = ReminderService.create!(user: @user, title: "Test reminder", scheduled_for: 1.day.from_now)
    Note.create!(
      tenant: @tenant, collective: @collective, created_by: @user, updated_by: @user,
      text: "Test reminder", subtype: "reminder",
      reminder_notification_id: notification.id, reminder_scheduled_for: 1.day.from_now,
    )
    Collective.clear_thread_scope

    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "[View all reminders](/notifications)"
  end

  test "whoami limits displayed reminders to 5" do
    sign_in_as(@user, tenant: @tenant)

    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    Tenant.current_id = @tenant.id
    7.times do |i|
      notification = ReminderService.create!(user: @user, title: "Reminder #{i}", scheduled_for: (i + 1).hours.from_now)
      Note.create!(
        tenant: @tenant, collective: @collective, created_by: @user, updated_by: @user,
        text: "Reminder #{i}", subtype: "reminder",
        reminder_notification_id: notification.id, reminder_scheduled_for: (i + 1).hours.from_now,
      )
    end
    Collective.clear_thread_scope

    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success

    # Should show only 5 reminders
    assert_includes response.body, "Reminder 0"
    assert_includes response.body, "Reminder 4"
    assert_not_includes response.body, "Reminder 5"
    assert_not_includes response.body, "Reminder 6"
  end

  # === Scratchpad Tests ===

  test "whoami shows scratchpad section for ai_agents" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(ai_agent)

    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users],
    )

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.plaintext_token}",
    }
    assert_response :success
    assert_includes response.body, "Your Scratchpad"
  end

  test "whoami shows scratchpad content when set" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent", agent_configuration: { "mode" => "external" })
    ai_agent.update_columns(agent_configuration: { "scratchpad" => "Remember to check the weekly sync notes." })
    @tenant.add_user!(ai_agent)

    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users],
    )

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.plaintext_token}",
    }
    assert_response :success
    assert_includes response.body, "Remember to check the weekly sync notes."
  end

  test "whoami shows empty scratchpad message when not set" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(ai_agent)

    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users],
    )

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.plaintext_token}",
    }
    assert_response :success
    assert_includes response.body, "Your scratchpad is empty"
  end

  test "whoami does not show scratchpad section for person users" do
    sign_in_as(@user, tenant: @tenant)

    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_not_includes response.body, "Your Scratchpad"
  end

  # === Scratchpad Action Tests ===

  test "actions_index shows update_scratchpad for ai_agents" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(ai_agent)

    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users create:all],
    )

    get "/whoami/actions", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.plaintext_token}",
    }
    assert_response :success
    assert_includes response.body, "update_scratchpad"
  end

  test "update_scratchpad succeeds for ai_agents" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(ai_agent)

    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users create:all],
    )

    post "/whoami/actions/update_scratchpad",
         params: { content: "Important notes for next task." },
         headers: {
           "Accept" => "text/markdown",
           "Authorization" => "Bearer #{api_token.plaintext_token}",
         }
    assert_response :success
    assert_includes response.body, "Scratchpad updated successfully"

    ai_agent.reload
    assert_equal "Important notes for next task.", ai_agent.agent_configuration["scratchpad"]
  end

  test "update_scratchpad returns 403 for non-ai_agents" do
    sign_in_as(@user, tenant: @tenant)

    post "/whoami/actions/update_scratchpad",
         params: { content: "Some content" },
         headers: { "Accept" => "text/markdown" }
    assert_response :forbidden
  end

  test "update_scratchpad rejects content exceeding max length" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(ai_agent)

    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users create:all],
    )

    long_content = "x" * 10_001

    post "/whoami/actions/update_scratchpad",
         params: { content: long_content },
         headers: {
           "Accept" => "text/markdown",
           "Authorization" => "Bearer #{api_token.plaintext_token}",
         }
    assert_response :unprocessable_entity
    assert_includes response.body, "exceeds maximum length"
  end

  test "update_scratchpad clears scratchpad with empty content" do
    @tenant.enable_api!

    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent", agent_configuration: { "mode" => "external" })
    ai_agent.update_columns(agent_configuration: { "scratchpad" => "Old notes" })
    @tenant.add_user!(ai_agent)

    api_token = ApiToken.create!(
      user: ai_agent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users create:all],
    )

    post "/whoami/actions/update_scratchpad",
         params: { content: "" },
         headers: {
           "Accept" => "text/markdown",
           "Authorization" => "Bearer #{api_token.plaintext_token}",
         }
    assert_response :success

    ai_agent.reload
    assert_nil ai_agent.agent_configuration["scratchpad"]
  end
end
