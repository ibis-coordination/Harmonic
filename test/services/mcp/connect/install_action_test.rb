# frozen_string_literal: true

require "test_helper"

class Mcp::Connect::InstallActionTest < ActiveSupport::TestCase
  setup do
    @mcp_url = "https://app.harmonic.local/mcp"
    @token = "test_token_abc123"
    @agent_handle = "hermes2"
    @server_name = "harmonic-hermes2"
  end

  def build(harness_key)
    Mcp::Connect::InstallAction.new(
      harness_key: harness_key,
      mcp_url: @mcp_url,
      token: @token,
      agent_handle: @agent_handle,
    ).to_h
  end

  # === Cursor (snippet) ===

  test "cursor returns a JSON snippet with agent-scoped server name" do
    result = build("cursor")
    assert_equal :snippet, result[:kind]
    assert_equal "json", result[:payload][:format]
    config = JSON.parse(result[:payload][:code])
    # Server name is scoped by handle so multiple agents coexist in one config
    server = config.dig("mcpServers", @server_name)
    refute_nil server, "expected mcpServers.#{@server_name} key"
    assert_equal @mcp_url, server["url"]
    assert_equal "Bearer #{@token}", server.dig("headers", "Authorization")
    assert_includes result[:payload][:paste_into], "~/.cursor/mcp.json"
  end

  # === Claude Code (cli_command) ===

  test "claude-code returns a single CLI command using the agent-scoped server name" do
    result = build("claude-code")
    assert_equal :cli_command, result[:kind]
    blocks = result[:payload][:blocks]
    assert_equal 1, blocks.length
    assert_includes blocks[0][:code], "claude mcp add"
    assert_includes blocks[0][:code], " #{@server_name} "
    assert_includes blocks[0][:code], @mcp_url
    assert_includes blocks[0][:code], "Bearer #{@token}"
  end

  # === Codex CLI (cli_command, multiple blocks) ===

  test "codex-cli returns three CLI command blocks with handle-scoped env var" do
    result = build("codex-cli")
    assert_equal :cli_command, result[:kind]
    blocks = result[:payload][:blocks]
    assert_equal 3, blocks.length

    env_var = "HARMONIC_MCP_TOKEN_HERMES2"
    export, add, flag = blocks
    assert_includes export[:code], "export #{env_var}=#{@token}"
    assert_includes add[:code], "codex mcp add #{@server_name}"
    assert_includes add[:code], "--bearer-token-env-var #{env_var}"
    refute_includes add[:code], @token  # token via env var, not literal in TOML
    assert_includes flag[:code], "experimental_use_rmcp_client = true"
  end

  # === Cline (snippet, JSON) ===

  test "cline returns a JSON snippet with streamableHttp type and agent-scoped server name" do
    result = build("cline")
    assert_equal :snippet, result[:kind]
    assert_equal "json", result[:payload][:format]
    config = JSON.parse(result[:payload][:code])
    server = config.dig("mcpServers", @server_name)
    refute_nil server, "expected mcpServers.#{@server_name} key"
    assert_equal "streamableHttp", server["type"]
    assert_equal @mcp_url, server["url"]
    assert_equal "Bearer #{@token}", server.dig("headers", "Authorization")
    assert result[:payload][:paste_into].present?
  end

  # === Continue (snippet, YAML) ===

  test "continue returns a YAML snippet with streamable-http type and agent-scoped name" do
    result = build("continue")
    assert_equal :snippet, result[:kind]
    assert_equal "yaml", result[:payload][:format]
    code = result[:payload][:code]
    assert_includes code, "name: #{@server_name}"
    assert_includes code, "type: streamable-http"
    assert_includes code, "url: #{@mcp_url}"
    assert_includes code, "Authorization: Bearer #{@token}"
    assert result[:payload][:paste_into].present?
  end

  # === Goose (snippet, header value) ===

  test "goose returns a snippet with the header value and agent-scoped extension name" do
    result = build("goose")
    assert_equal :snippet, result[:kind]
    assert_equal "text", result[:payload][:format]
    assert_equal "Bearer #{@token}", result[:payload][:code]
    assert_includes result[:payload][:paste_into], "goose configure"
    assert_includes result[:payload][:paste_into], @mcp_url
    assert_includes result[:payload][:paste_into], @server_name
  end

  # === Hermes Agent (credentials) ===

  test "hermes-agent returns credentials with help link" do
    result = build("hermes-agent")
    assert_equal :credentials, result[:kind]
    assert_equal @mcp_url, result[:payload][:mcp_url]
    assert_equal @token, result[:payload][:token]
    assert_equal "/help/mcp/connect/hermes-agent", result[:payload][:help_path]
  end

  # === OpenClaw (credentials) ===

  test "openclaw returns credentials with help link" do
    result = build("openclaw")
    assert_equal :credentials, result[:kind]
    assert_equal @mcp_url, result[:payload][:mcp_url]
    assert_equal @token, result[:payload][:token]
    assert_equal "/help/mcp/connect/openclaw", result[:payload][:help_path]
  end

  # === Unknown harness ===

  test "unknown harness raises" do
    assert_raises(ArgumentError) do
      build("nonexistent")
    end
  end

  test "server name is scoped by agent handle so multiple agents coexist" do
    alice = Mcp::Connect::InstallAction.new(
      harness_key: "cline", mcp_url: @mcp_url, token: "alice_token", agent_handle: "alice",
    ).to_h
    bob = Mcp::Connect::InstallAction.new(
      harness_key: "cline", mcp_url: @mcp_url, token: "bob_token", agent_handle: "bob",
    ).to_h
    alice_keys = JSON.parse(alice[:payload][:code])["mcpServers"].keys
    bob_keys = JSON.parse(bob[:payload][:code])["mcpServers"].keys
    assert_equal ["harmonic-alice"], alice_keys
    assert_equal ["harmonic-bob"], bob_keys
    # If both blocks are merged into one mcp.json, the agents coexist.
    assert_equal [], alice_keys & bob_keys
  end
end
