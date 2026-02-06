require "test_helper"

class WhoamiControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
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

  test "whoami page shows user studios section" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami"
    assert_response :success
    assert_includes response.body, "Your Studios"
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

  # === Subagent User Tests ===

  test "whoami shows subagent parent info" do
    @tenant.enable_api!

    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)

    # Create API token for subagent
    api_token = ApiToken.create!(
      user: subagent,
      tenant: @tenant,
      name: "Test Token",
      scopes: %w[read:users],
    )

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.plaintext_token}",
    }
    assert_response :success
    assert_includes response.body, "subagent"
    assert_includes response.body, @user.display_name
  end

  test "whoami shows subagent identity prompt when set" do
    @tenant.enable_api!

    subagent = create_subagent(parent: @user, name: "Test Assistant")
    subagent.update!(agent_configuration: { "identity_prompt" => "You are a helpful assistant for scheduling meetings." })
    @tenant.add_user!(subagent)

    api_token = ApiToken.create!(
      user: subagent,
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

  test "whoami does not show identity prompt section when not set" do
    @tenant.enable_api!

    subagent = create_subagent(parent: @user, name: "Test Agent")
    @tenant.add_user!(subagent)

    api_token = ApiToken.create!(
      user: subagent,
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

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    ReminderService.create!(user: @user, title: "Upcoming reminder", scheduled_for: 1.day.from_now)
    Superagent.clear_thread_scope

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

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    ReminderService.create!(user: @user, title: "Test reminder", scheduled_for: 1.day.from_now)
    Superagent.clear_thread_scope

    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "[View all reminders](/notifications)"
  end

  test "whoami limits displayed reminders to 5" do
    sign_in_as(@user, tenant: @tenant)

    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    Tenant.current_id = @tenant.id
    7.times do |i|
      ReminderService.create!(user: @user, title: "Reminder #{i}", scheduled_for: (i + 1).hours.from_now)
    end
    Superagent.clear_thread_scope

    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success

    # Should show only 5 reminders
    assert_includes response.body, "Reminder 0"
    assert_includes response.body, "Reminder 4"
    assert_not_includes response.body, "Reminder 5"
    assert_not_includes response.body, "Reminder 6"
  end

  # === Scratchpad Tests ===

  test "whoami shows scratchpad section for subagents" do
    @tenant.enable_api!

    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)

    api_token = ApiToken.create!(
      user: subagent,
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

    subagent = create_subagent(parent: @user, name: "Test Subagent")
    subagent.update!(agent_configuration: { "scratchpad" => "Remember to check the weekly sync notes." })
    @tenant.add_user!(subagent)

    api_token = ApiToken.create!(
      user: subagent,
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

    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)

    api_token = ApiToken.create!(
      user: subagent,
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

  test "actions_index shows update_scratchpad for subagents" do
    @tenant.enable_api!

    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)

    api_token = ApiToken.create!(
      user: subagent,
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

  test "update_scratchpad succeeds for subagents" do
    @tenant.enable_api!

    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)

    api_token = ApiToken.create!(
      user: subagent,
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

    subagent.reload
    assert_equal "Important notes for next task.", subagent.agent_configuration["scratchpad"]
  end

  test "update_scratchpad returns 403 for non-subagents" do
    sign_in_as(@user, tenant: @tenant)

    post "/whoami/actions/update_scratchpad",
         params: { content: "Some content" },
         headers: { "Accept" => "text/markdown" }
    assert_response :forbidden
  end

  test "update_scratchpad rejects content exceeding max length" do
    @tenant.enable_api!

    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)

    api_token = ApiToken.create!(
      user: subagent,
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
    assert_response :success # Action error returns 200 with error message
    assert_includes response.body, "exceeds maximum length"
  end

  test "update_scratchpad clears scratchpad with empty content" do
    @tenant.enable_api!

    subagent = create_subagent(parent: @user, name: "Test Subagent")
    subagent.update!(agent_configuration: { "scratchpad" => "Old notes" })
    @tenant.add_user!(subagent)

    api_token = ApiToken.create!(
      user: subagent,
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

    subagent.reload
    assert_nil subagent.agent_configuration["scratchpad"]
  end
end
