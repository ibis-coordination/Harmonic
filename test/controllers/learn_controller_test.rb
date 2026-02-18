require "test_helper"

class LearnControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
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
    assert_includes response.body, "AI Agency"
    assert_includes response.body, "Superagency"
    assert_includes response.body, "Awareness Indicators"
    assert_includes response.body, "Acceptance Voting"
    assert_includes response.body, "Reciprocal Commitment"
  end

  # === AI Agency (GET /learn/ai-agency) HTML Tests ===

  test "unauthenticated user can access ai_agency page when login not required" do
    @tenant.settings["require_login"] = false
    @tenant.save!
    get "/learn/ai-agency"
    assert_response :success
    assert_includes response.body, "AI Agency"
  end

  test "authenticated user can access ai_agency page" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/ai-agency"
    assert_response :success
    assert_includes response.body, "AI Agency"
  end

  test "ai_agency page explains what a ai_agent is" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/ai-agency"
    assert_response :success
    assert_includes response.body, "parent user"
    assert_includes response.body, "responsible"
  end

  test "ai_agency page explains visible accountability" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/ai-agency"
    assert_response :success
    assert_includes response.body, "Visible Accountability"
    assert_includes response.body, "transparency"
  end

  # === AI Agency (GET /learn/ai-agency) Markdown Tests ===

  test "ai_agency responds to markdown format" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/ai-agency", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# AI Agency"
  end

  test "markdown ai_agency includes key sections" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/ai-agency", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "## Visible Accountability"
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

  test "superagency page explains what a collective is" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency"
    assert_response :success
    assert_includes response.body, "collective"
    assert_includes response.body, "unified agent"
  end

  test "superagency page mentions studios and scenes" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency"
    assert_response :success
    assert_includes response.body, "studios"
    assert_includes response.body, "Scenes"
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

  test "markdown superagency includes key sections" do
    sign_in_as(@user, tenant: @tenant)
    get "/learn/superagency", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "## Representation"
  end

end
