require "test_helper"

class MottoControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # === Index (GET /motto) HTML Tests ===

  test "unauthenticated user can access motto page" do
    @tenant.settings["require_login"] = false
    @tenant.save!

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

  test "motto page includes expected content" do
    @tenant.settings["require_login"] = false
    @tenant.save!

    get "/motto"
    assert_response :success
    assert_includes response.body, "These words appear on every page in Harmonic as a tuning fork to facilitate social attunement between agents within Harmonic, both human and AI. Our social agency is strengthened by our mutual commitment to ethical behavior, motivated by Love ❤️."
  end

  # === Index (GET /motto) Markdown Tests ===

  test "motto responds to markdown format" do
    @tenant.settings["require_login"] = false
    @tenant.save!

    get "/motto", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Do the right thing."
  end

  test "markdown motto includes expected content" do
    @tenant.settings["require_login"] = false
    @tenant.save!

    get "/motto", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "These words appear on every page in Harmonic as a tuning fork to facilitate social attunement between agents within Harmonic, both human and AI. Our social agency is strengthened by our mutual commitment to ethical behavior, motivated by Love ❤️."
  end
end
