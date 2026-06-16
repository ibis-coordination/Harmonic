# frozen_string_literal: true

require "test_helper"

class HelpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
    @tenant.set_feature_flag!("api", true)
    sign_in_as(@user, tenant: @tenant)
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
    assert_match(/href="\/help"[^>]*>Help/, response.body)
    assert_match(/href="\/help\/mcp"[^>]*>MCP/, response.body)
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
    slugs = %w[cursor claude-code claude-desktop codex codex-cloud cline continue goose hermes-agent openclaw]
    slugs.each do |slug|
      get "/help/mcp/connect/#{slug}"
      assert_response :success, "Expected /help/mcp/connect/#{slug} to render but got #{response.status}"
    end
  end

  test "old codex-cli slug returns 404 (renamed to codex)" do
    get "/help/mcp/connect/codex-cli"
    assert_response :not_found
  end

  test "/help/mcp/connect/codex-cloud renders the Codex Cloud setup guide" do
    get "/help/mcp/connect/codex-cloud"
    assert_response :success
    assert_includes response.body, "Connecting Codex Cloud to Harmonic"
  end
end
