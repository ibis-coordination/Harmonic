require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # === Show (GET /u/:handle) Tests ===

  test "can view user profile" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, @user.display_name
  end

  test "can view user profile in markdown format" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# User: #{@user.display_name}"
  end

  # === Subagent Count Tests (HTML) ===

  test "person user profile shows subagent count when they have subagents" do
    subagent1 = create_subagent(parent: @user, name: "Subagent One")
    subagent2 = create_subagent(parent: @user, name: "Subagent Two")
    @tenant.add_user!(subagent1)
    @tenant.add_user!(subagent2)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, "Has 2 subagents"
  end

  test "person user profile shows singular subagent when they have one" do
    subagent = create_subagent(parent: @user, name: "Only Subagent")
    @tenant.add_user!(subagent)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_includes response.body, "Has 1 subagent"
    assert_not_includes response.body, "Has 1 subagents"
  end

  test "person user profile does not show subagent count when they have none" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    assert_not_includes response.body, "Has 0 subagent"
    assert_not_includes response.body, "subagent"
  end

  test "subagent profile does not show subagent count" do
    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)
    @superagent.add_user!(subagent)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{subagent.handle}"
    assert_response :success
    # Subagent shows "subagent" badge and "Managed by" but not "Has N subagents"
    assert_includes response.body, "subagent"
    assert_not_includes response.body, "Has 0 subagent"
    assert_not_includes response.body, "Has 1 subagent"
  end

  # === Subagent Count Tests (Markdown) ===

  test "markdown person profile shows subagent count when they have subagents" do
    subagent1 = create_subagent(parent: @user, name: "Subagent One")
    subagent2 = create_subagent(parent: @user, name: "Subagent Two")
    @tenant.add_user!(subagent1)
    @tenant.add_user!(subagent2)

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Has 2 subagents"
  end

  test "markdown person profile does not show subagent count when they have none" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_not_includes response.body, "Has 0 subagent"
  end

  # === Subagent Count Scoping Tests ===

  test "subagent count only includes subagents in current tenant" do
    # Create two subagents
    subagent1 = create_subagent(parent: @user, name: "Subagent In Tenant")
    subagent2 = create_subagent(parent: @user, name: "Subagent Not In Tenant")

    # Only add subagent1 to the current tenant
    @tenant.add_user!(subagent1)
    # subagent2 is not added to the tenant

    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}"
    assert_response :success
    # Should only show 1 subagent (the one in this tenant)
    assert_includes response.body, "Has 1 subagent"
    assert_not_includes response.body, "Has 2 subagents"
  end
end
