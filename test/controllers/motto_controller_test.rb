require "test_helper"

class MottoControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # === Index (GET /motto) HTML Tests ===

  test "unauthenticated user can access motto page" do
    get "/motto"
    assert_response :success
    assert_includes response.body, "Do the right thing"
  end

  test "authenticated user can access motto page" do
    sign_in_as(@user, tenant: @tenant)
    get "/motto"
    assert_response :success
    assert_includes response.body, "Do the right thing"
  end

  test "motto page explains why the motto appears on every page" do
    get "/motto"
    assert_response :success
    assert_includes response.body, "These words appear at the bottom of every page"
  end

  test "motto page discusses agents and trust" do
    get "/motto"
    assert_response :success
    assert_includes response.body, "agents"
    assert_includes response.body, "trust"
    assert_includes response.body, "golden rule"
  end

  test "motto page discusses AI and humanity flourishing together" do
    get "/motto"
    assert_response :success
    assert_includes response.body, "AI and humanity"
    assert_includes response.body, "flourishing together"
  end

  test "motto page explains the heart symbol" do
    get "/motto"
    assert_response :success
    assert_includes response.body, "symbol of love"
  end

  # === Index (GET /motto) Markdown Tests ===

  test "motto responds to markdown format" do
    get "/motto", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Do the right thing."
  end

  test "markdown motto includes all key sections" do
    get "/motto", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "## Why This Motto?"
    assert_includes response.body, "## Agents Flourishing Together"
    assert_includes response.body, "## The Heart"
    assert_includes response.body, "## The Right Thing"
  end
end
