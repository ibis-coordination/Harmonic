require "test_helper"

class LearnControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # === Index (GET /learn) Tests ===

  test "unauthenticated user can access learn index when login not required" do
    @tenant.settings["require_login"] = false
    @tenant.save!
    get "/learn"
    assert_response :success
    assert_includes response.body, "Learn"
  end

  test "unauthenticated user is redirected when login required" do
    get "/learn"
    assert_response :redirect
  end

  test "learn index links to all concept pages" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn"
    assert_response :success
    assert_includes response.body, "Subagency"
    assert_includes response.body, "Superagency"
    assert_includes response.body, "Memory"
    assert_includes response.body, "Awareness Indicators"
    assert_includes response.body, "Acceptance Voting"
    assert_includes response.body, "Reciprocal Commitment"
  end

  # === Subagency (GET /learn/subagency) HTML Tests ===

  test "unauthenticated user can access subagency page when login not required" do
    @tenant.settings["require_login"] = false
    @tenant.save!
    get "/learn/subagency"
    assert_response :success
    assert_includes response.body, "Subagency"
  end

  test "authenticated user can access subagency page" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/subagency"
    assert_response :success
    assert_includes response.body, "Subagency"
  end

  test "subagency page explains what a subagent is" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/subagency"
    assert_response :success
    assert_includes response.body, "What is a Subagent?"
    assert_includes response.body, "parent user"
  end

  test "subagency page explains parent responsibility" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/subagency"
    assert_response :success
    assert_includes response.body, "Parent's Responsibility"
    assert_includes response.body, "accountable"
  end

  test "subagency page explains visible accountability" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/subagency"
    assert_response :success
    assert_includes response.body, "Visible Accountability"
    assert_includes response.body, "transparency"
  end

  test "subagency page has section for subagents" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/subagency"
    assert_response :success
    assert_includes response.body, "For Subagents: Understanding Your Role"
  end

  # === Subagency (GET /learn/subagency) Markdown Tests ===

  test "subagency responds to markdown format" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/subagency", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Subagency"
  end

  test "markdown subagency includes all key sections" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/subagency", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "## What is a Subagent?"
    assert_includes response.body, "## The Parent's Responsibility"
    assert_includes response.body, "## Visible Accountability"
    assert_includes response.body, "## For Subagents: Understanding Your Role"
    assert_includes response.body, "## Why This Structure Exists"
  end

  # === Subagency Dynamic Content Tests ===

  test "subagent user sees their parent info via session" do
    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)
    @global_superagent.add_user!(subagent)

    # Impersonate the subagent through parent
    sign_in_as(@user, tenant: @tenant)
    post "/u/#{subagent.handle}/impersonate"

    get "/learn/subagency"
    assert_response :success
    assert_includes response.body, "Your Subagent Status"
    assert_includes response.body, "You are a subagent"
  end

  test "person user sees their subagents section" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/subagency"
    assert_response :success
    assert_includes response.body, "Your Subagents"
  end

  test "person user with subagents sees them listed" do
    subagent = create_subagent(parent: @user, name: "My Test Subagent")
    @tenant.add_user!(subagent)

    sign_in_as(@user, tenant: @tenant)
    get "/learn/subagency"
    assert_response :success
    assert_includes response.body, "my-test-subagent"
    assert_includes response.body, "You are responsible for the actions of these subagents"
  end

  # === Superagency (GET /learn/superagency) HTML Tests ===

  test "unauthenticated user can access superagency page when login not required" do
    @tenant.settings["require_login"] = false
    @tenant.save!
    get "/learn/superagency"
    assert_response :success
    assert_includes response.body, "Superagency"
  end

  test "authenticated user can access superagency page" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency"
    assert_response :success
    assert_includes response.body, "Superagency"
  end

  test "superagency page explains what a superagent is" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency"
    assert_response :success
    assert_includes response.body, "What is a Superagent?"
    assert_includes response.body, "collective"
  end

  test "superagency page explains studios and scenes" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency"
    assert_response :success
    assert_includes response.body, "Studios"
    assert_includes response.body, "Scenes"
    assert_includes response.body, "Private"
    assert_includes response.body, "Public"
  end

  test "superagency page explains representation" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency"
    assert_response :success
    assert_includes response.body, "Representation"
    assert_includes response.body, "representatives"
  end

  # === Superagency (GET /learn/superagency) Markdown Tests ===

  test "superagency responds to markdown format" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Superagency"
  end

  test "markdown superagency includes all key sections" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "## What is a Superagent?"
    assert_includes response.body, "## Types of Superagents"
    assert_includes response.body, "## Representation"
    assert_includes response.body, "## Why This Structure Exists"
  end

  # === Superagency Dynamic Content Tests ===

  test "authenticated user sees their superagents section" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency"
    assert_response :success
    assert_includes response.body, "Your Superagents"
  end

  # === Memory (GET /learn/memory) HTML Tests ===

  test "unauthenticated user can access memory page when login not required" do
    @tenant.settings["require_login"] = false
    @tenant.save!
    get "/learn/memory"
    assert_response :success
    assert_includes response.body, "Memory"
  end

  test "authenticated user can access memory page" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/memory"
    assert_response :success
    assert_includes response.body, "Memory"
  end

  test "memory page explains distributed memory" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/memory"
    assert_response :success
    assert_includes response.body, "distributed"
    assert_includes response.body, "Personal reminders"
    assert_includes response.body, "Activity history"
  end

  test "memory page includes practical guidance" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/memory"
    assert_response :success
    assert_includes response.body, "Practical guidance"
  end

  # === Memory (GET /learn/memory) Markdown Tests ===

  test "memory responds to markdown format" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/memory", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Memory"
  end

  test "markdown memory includes key content" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/memory", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "Personal reminders"
    assert_includes response.body, "Activity history"
    assert_includes response.body, "Practical guidance"
  end
end
