require "test_helper"

class HelpPagesTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    @tenant.enable_feature_flag!("trio")
    @user = @global_user
    @api_token = ApiToken.create!(
      user: @user,
      tenant: @tenant,
      name: "Help Test #{SecureRandom.hex(4)}",
      scopes: ApiToken.valid_scopes
    )
    @md_headers = {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{@api_token.plaintext_token}",
    }
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    sign_in_as(@user, tenant: @tenant)
  end

  TOPICS = [
    "privacy", "collectives", "notes", "reminder-notes", "table-notes",
    "decisions", "executive-decisions", "lottery-decisions",
    "commitments", "calendar-events", "policies", "cycles", "search", "links", "lists",
    "agents", "trio", "automations", "api", "rest-api", "markdown-ui", "notifications", "representation",
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
    assert_includes response.body, "/help/calendar-events"
    assert_includes response.body, "/help/policies"
  end

  test "help index links to automations (always shown, not feature-gated)" do
    @tenant.disable_feature_flag!("api")
    @tenant.disable_feature_flag!("internal_ai_agents")
    @tenant.disable_feature_flag!("external_ai_agents")
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
      assert_no_match(/\A\s*---\napp: Harmonic/, response.body)
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
    assert_not_includes response.body, "actions:"
  end

  # =========================================================================
  # Feature flag gating
  # =========================================================================

  GATED_TOPICS = {
    "api" => "api",
    "rest-api" => "api",
    "trio" => "trio",
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
      assert_not_includes response.body, "/help/#{topic}"
    end

    test "help index shows #{topic} link when #{flag} feature flag is enabled" do
      @tenant.enable_feature_flag!(flag)
      get "/help"
      assert_response :success
      assert_includes response.body, "/help/#{topic}"
    end
  end

  test "help agents returns 404 when both ai_agents feature flags are disabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @tenant.disable_feature_flag!("external_ai_agents")
    get "/help/agents"
    assert_response :not_found
  end

  test "help agents renders when only internal_ai_agents flag is enabled" do
    @tenant.disable_feature_flag!("external_ai_agents")
    @tenant.enable_feature_flag!("internal_ai_agents")
    get "/help/agents"
    assert_response :success
  end

  test "help agents renders when only external_ai_agents flag is enabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    get "/help/agents"
    assert_response :success
  end

  test "help index hides agents link when both ai_agents feature flags are disabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @tenant.disable_feature_flag!("external_ai_agents")
    get "/help"
    assert_response :success
    assert_not_includes response.body, "/help/agents"
  end

  test "help index shows agents link when any ai_agents feature flag is enabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    get "/help"
    assert_response :success
    assert_includes response.body, "/help/agents"
  end

  # Billing is tested outside the GATED_TOPICS loop because enabling the
  # stripe_billing flag activates the application-level billing gate — the
  # setup user's external API token would make them billable and every
  # request would bounce to /billing. Deleting the token first keeps
  # billable_quantity at 0 so the gate passes.
  test "help billing returns 404 when stripe_billing feature flag is disabled" do
    @tenant.disable_feature_flag!("stripe_billing")
    get "/help/billing"
    assert_response :not_found
  end

  test "help billing renders HTML when stripe_billing feature flag is enabled" do
    @api_token.delete!
    @tenant.enable_feature_flag!("stripe_billing")
    get "/help/billing"
    assert_response :success
    assert_includes response.body, "pulse-prose"
    assert_includes response.body, "$3"
  end

  test "help billing renders markdown when stripe_billing feature flag is enabled" do
    @api_token.delete!
    @tenant.enable_feature_flag!("stripe_billing")
    get "/help/billing", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/^# Billing/, response.body)
  end

  test "help index hides billing link when stripe_billing feature flag is disabled" do
    @tenant.disable_feature_flag!("stripe_billing")
    get "/help"
    assert_response :success
    assert_not_includes response.body, "/help/billing"
  end

  test "help index shows billing link when stripe_billing feature flag is enabled" do
    @api_token.delete!
    @tenant.enable_feature_flag!("stripe_billing")
    get "/help"
    assert_response :success
    assert_includes response.body, "/help/billing"
  end
end
