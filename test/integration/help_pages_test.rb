require "test_helper"

class HelpPagesTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @tenant.enable_feature_flag!("ai_agents")
    @user = @global_user
    @api_token = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      name: "Help Test #{SecureRandom.hex(4)}",
      scopes: ApiToken.valid_scopes,
    )
    @md_headers = {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{@api_token.plaintext_token}",
    }
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    sign_in_as(@user, tenant: @tenant)
  end

  TOPICS = %w[
    privacy collectives notes reminder-notes table-notes
    decisions executive-decisions lottery-decisions
    commitments cycles search links
    agents automations api rest-api markdown-ui notifications representation
  ].freeze

  # =========================================================================
  # HTML rendering
  # =========================================================================

  test "help index renders HTML" do
    get "/help"
    assert_response :success
    assert_includes response.body, "Help"
    assert_includes response.body, "/help/collectives"
    assert_includes response.body, "/help/privacy"
  end

  test "help index lists subtype topics nested under their parents" do
    get "/help"
    assert_response :success
    assert_includes response.body, "/help/reminder-notes"
    assert_includes response.body, "/help/table-notes"
    assert_includes response.body, "/help/executive-decisions"
    assert_includes response.body, "/help/lottery-decisions"
  end

  test "help index links to automations (always shown, not feature-gated)" do
    @tenant.disable_feature_flag!("api")
    @tenant.disable_feature_flag!("ai_agents")
    get "/help"
    assert_response :success
    assert_includes response.body, "/help/automations"
    assert_match(/Agency (&amp;|&) Integration/, response.body)
  end

  TOPICS.each do |topic|
    test "help #{topic} renders HTML" do
      get "/help/#{topic}"
      assert_response :success
      assert_includes response.body, "pulse-prose"
      # Should not start with raw YAML frontmatter — that would mean the
      # markdown layout leaked into the HTML response.
      refute_match(/\A\s*---\napp: Harmonic/, response.body)
    end
  end

  # =========================================================================
  # Markdown rendering
  # =========================================================================

  test "help index renders markdown" do
    get "/help", headers: @md_headers
    assert_response :success
    assert_includes response.body, "# Help"
    assert_includes response.body, "/help/collectives"
  end

  TOPICS.each do |topic|
    test "help #{topic} renders markdown" do
      get "/help/#{topic}", headers: @md_headers
      assert_response :success
      assert_match(/^# /, response.body)
    end
  end

  # =========================================================================
  # Content accuracy
  # =========================================================================

  test "help pages have no actions" do
    get "/help", headers: @md_headers
    assert_response :success
    refute_includes response.body, "actions:"
  end

  # =========================================================================
  # Feature flag gating
  # =========================================================================

  GATED_TOPICS = {
    "api" => "api",
    "rest-api" => "api",
    "agents" => "ai_agents",
  }.freeze

  GATED_TOPICS.each do |topic, flag|
    test "help #{topic} returns 404 when #{flag} feature flag is disabled" do
      @tenant.disable_feature_flag!(flag)
      get "/help/#{topic}"
      assert_response :not_found
    end

    test "help #{topic} renders when #{flag} feature flag is enabled" do
      @tenant.enable_feature_flag!(flag)
      get "/help/#{topic}"
      assert_response :success
    end

    test "help index hides #{topic} link when #{flag} feature flag is disabled" do
      @tenant.disable_feature_flag!(flag)
      get "/help"
      assert_response :success
      refute_includes response.body, "/help/#{topic}"
    end

    test "help index shows #{topic} link when #{flag} feature flag is enabled" do
      @tenant.enable_feature_flag!(flag)
      get "/help"
      assert_response :success
      assert_includes response.body, "/help/#{topic}"
    end
  end
end
