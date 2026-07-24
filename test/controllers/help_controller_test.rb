# frozen_string_literal: true

require "test_helper"

class HelpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    @tenant.set_feature_flag!("api", true)
    @tenant.set_feature_flag!("external_ai_agents", true)
    sign_in_as(@user, tenant: @tenant)
  end

  test "/help/trio renders when the trio flag is enabled" do
    @tenant.set_feature_flag!("trio", true)
    get "/help/trio"
    assert_response :success
    assert_match(/Trio/, response.body)
    # All three personas and the differences section
    assert_match(/Melody/, response.body)
    assert_match(/Counterpoint/, response.body)
    assert_match(/Cadence/, response.body)
    assert_match(/collective is the principal/i, response.body)
  end

  test "/help/trio renders in markdown too" do
    @tenant.set_feature_flag!("trio", true)
    get "/help/trio", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Trio/, response.body)
  end

  test "/help/trio 404s when the trio flag is disabled on the tenant" do
    @tenant.set_feature_flag!("trio", false)
    get "/help/trio"
    assert_response :not_found
  end

  test "/help/funding-pools states the visibility rule and renders when billing is enabled" do
    @tenant.set_feature_flag!("stripe_billing", true)
    get "/help/funding-pools"
    assert_response :success
    assert_match(/Funding Pools/, response.body)
    # The baseline rule of pooled funding, stated as a rule users can rely on.
    assert_match(/activity every pool member can see/i, response.body)
    # Honest about the operator-enabled exception path.
    assert_match(/consent/i, response.body)
  end

  test "/help/funding-pools renders in markdown too" do
    @tenant.set_feature_flag!("stripe_billing", true)
    get "/help/funding-pools", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/activity every pool member can see/i, response.body)
  end

  test "/help/funding-pools 404s when billing is disabled on the tenant" do
    @tenant.set_feature_flag!("stripe_billing", false)
    get "/help/funding-pools"
    assert_response :not_found
  end

  test "help index links funding pools when billing is enabled" do
    @tenant.set_feature_flag!("stripe_billing", true)
    get "/help"
    assert_response :success
    assert_match "/help/funding-pools", response.body
  end

  test "/help/collectives links to the funding pools page without duplicating it" do
    @tenant.set_feature_flag!("stripe_billing", true)
    get "/help/collectives"
    assert_response :success
    assert_match "/help/funding-pools", response.body
    # The mechanics live on the dedicated page now.
    assert_no_match(/Membership and funding are separate/, response.body)
  end

  test "/help/self-hosting-agents leads with user-facing guidance" do
    get "/help/self-hosting-agents"
    assert_response :success
    # Should read as a "how do I run an agent on my own hardware" page, not
    # a wire-protocol spec. Spot-check headings users would expect.
    assert_match(/Self-hosting agents/, response.body)
    assert_match(/Pull vs\. push/i, response.body)
    assert_match(/Push mode setup/i, response.body)
    assert_match(/Connect harmonic-bridge/, response.body)
  end

  test "/help/self-hosting-agents documents the Sprites path" do
    get "/help/self-hosting-agents"
    assert_response :success
    # Sprites is one hosting option; setup-sprite automates the bridge side.
    assert_match(/Sprites/, response.body)
    assert_match(/setup-sprite --from/, response.body)
    # Harness wiring is explicit opt-in via --harness; no harness is assumed.
    assert_match(/--harness/, response.body)
    # Sprites install/auth is Fly's product — link their docs, don't inline them.
    assert_match(/docs\.sprites\.dev/, response.body)
    assert_no_match(/install\.sh/, response.body)
    assert_no_match(/recommended/i, response.body)
    # The generic-host instructions must survive alongside the Sprites path.
    assert_match(/cloudflared|reverse proxy/, response.body)
  end

  test "/help/self-hosting-agents renders in markdown too" do
    get "/help/self-hosting-agents", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Self-hosting agents/, response.body)
  end

  test "/help/webhooks documents the canonical signing scheme and three flavors" do
    get "/help/webhooks"
    assert_response :success
    # Names the three flavors so a reader can orient
    assert_match(/Notification webhook/, response.body)
    assert_match(/Automation webhook action/, response.body)
    assert_match(/Automation webhook trigger/, response.body)
    # Documents the wire format that's hardcoded in WebhookDeliveryService
    assert_match(/X-Harmonic-Signature/, response.body)
    assert_match(/X-Harmonic-Timestamp/, response.body)
    assert_match(/HMAC-SHA256/i, response.body)
  end

  test "/help/webhooks renders in markdown too" do
    get "/help/webhooks", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Webhooks/, response.body)
  end

  test "/help/mcp/connect/cursor renders the Cursor setup guide" do
    get "/help/mcp/connect/cursor"
    assert_response :success
    assert_includes response.body, "Connecting Cursor to Harmonic"
  end

  test "/help/mcp/connect/<harness> breadcrumb links to /help/mcp" do
    get "/help/mcp/connect/cursor"
    assert_response :success
    # Breadcrumb should expose Home > Help > MCP > Connect <Harness>
    assert_match(%r{href="/help"[^>]*>Help}, response.body)
    assert_match(%r{href="/help/mcp"[^>]*>MCP}, response.body)
    assert_includes response.body, "Connect Cursor"
  end

  test "/help/mcp/connect/claude-code renders the Claude Code setup guide" do
    get "/help/mcp/connect/claude-code"
    assert_response :success
    assert_includes response.body, "Connecting Claude Code to Harmonic"
  end

  test "/help/mcp/connect/hermes-agent renders the Hermes Agent setup guide" do
    get "/help/mcp/connect/hermes-agent"
    assert_response :success
    assert_includes response.body, "Connecting Hermes Agent to Harmonic"
  end

  test "/help/mcp/connect/openclaw renders the OpenClaw setup guide" do
    get "/help/mcp/connect/openclaw"
    assert_response :success
    assert_includes response.body, "Connecting OpenClaw to Harmonic"
  end

  test "/help/mcp/connect/<unknown> returns 404" do
    get "/help/mcp/connect/nonexistent-harness"
    assert_response :not_found
  end

  test "/help/mcp/connect/cursor is unavailable when api feature flag is off" do
    @tenant.set_feature_flag!("api", false)
    get "/help/mcp/connect/cursor"
    assert_response :not_found
  end

  test "/help/mcp/connect/cursor responds to markdown format" do
    get "/help/mcp/connect/cursor", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Connecting Cursor to Harmonic"
  end

  test "all harness slugs render successfully" do
    slugs = ["cursor", "claude-code", "claude-desktop", "codex", "codex-cloud", "cline", "continue", "goose", "hermes-agent", "openclaw"]
    slugs.each do |slug|
      get "/help/mcp/connect/#{slug}"
      assert_response :success, "Expected /help/mcp/connect/#{slug} to render but got #{response.status}"
    end
  end

  test "old codex-cli slug returns 404 (renamed to codex)" do
    get "/help/mcp/connect/codex-cli"
    assert_response :not_found
  end

  test "/help/agents/getting-started renders the agent orientation doc" do
    get "/help/agents/getting-started"
    assert_response :success
    assert_includes response.body, "Getting started as an agent"
  end

  test "/help/agents/getting-started breadcrumb links to /help/agents" do
    get "/help/agents/getting-started"
    assert_response :success
    assert_match(%r{href="/help/agents"[^>]*>Agents}, response.body)
    assert_includes response.body, "Getting started"
  end

  test "/help/agents/getting-started 404s when the agents topic is unavailable" do
    @tenant.set_feature_flag!("internal_ai_agents", false)
    @tenant.set_feature_flag!("external_ai_agents", false)
    get "/help/agents/getting-started"
    assert_response :not_found
  end

  test "/help/agents/getting-started responds to markdown format" do
    get "/help/agents/getting-started", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Getting started as an agent"
  end

  test "/help/mcp/connect/codex-cloud renders the Codex Cloud setup guide" do
    get "/help/mcp/connect/codex-cloud"
    assert_response :success
    assert_includes response.body, "Connecting Codex Cloud to Harmonic"
  end

  test "/help/agents/representation renders the agent representation doc" do
    get "/help/agents/representation"
    assert_response :success
    assert_includes response.body, "Representation as an agent"
  end

  test "/help/agents/representation 404s when the agents topic is unavailable" do
    @tenant.set_feature_flag!("internal_ai_agents", false)
    @tenant.set_feature_flag!("external_ai_agents", false)
    get "/help/agents/representation"
    assert_response :not_found
  end

  test "/help/agents/representation responds to markdown format" do
    get "/help/agents/representation", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_includes response.body, "# Representation as an agent"
    assert_includes response.body, "representation_session_id"
    assert_includes response.body, "acting_as"
  end
end
