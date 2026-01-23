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
    assert_includes response.body, @user.email
    assert_includes response.body, @user.handle
  end

  test "whoami page shows current tenant info" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami"
    assert_response :success
    assert_includes response.body, @tenant.name
    assert_includes response.body, @tenant.subdomain
  end

  test "whoami page shows current superagent info" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami"
    assert_response :success
    assert_includes response.body, @superagent.name
    assert_includes response.body, @superagent.handle
  end

  # === Index (GET /whoami) Markdown Tests ===

  test "whoami responds to markdown format" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Who Am I"
    assert_includes response.body, @user.display_name
  end

  test "markdown whoami shows user info in table format" do
    sign_in_as(@user, tenant: @tenant)
    get "/whoami", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "| Property | Value |"
    assert_includes response.body, "| Name |"
    assert_includes response.body, "| Handle |"
    assert_includes response.body, "| Email |"
    assert_includes response.body, "| Type |"
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
      token: SecureRandom.hex(32),
      scopes: %w[read:users],
    )

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{api_token.token}",
    }
    assert_response :success
    assert_includes response.body, "subagent"
    assert_includes response.body, @user.display_name
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
end
