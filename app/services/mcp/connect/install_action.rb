# typed: true

# Renders an install action for a given harness slug + freshly-minted
# Bearer token. Returns a hash with :kind and :payload that the install-
# action view dispatches on.
#
# Three kinds:
#   :cli_command  — one or more labeled command blocks (Claude Code, Codex CLI)
#   :snippet      — a config block to paste into a file (Cursor, Cline, Continue, Goose)
#   :credentials  — raw MCP URL + token + help-page link (Hermes Agent, OpenClaw)
#
# We avoid the :deeplink shape (e.g. Cursor's "Add to Cursor" URL or Goose's
# goose:// extension URL) because both bake the token into a URL that
# transits a third party (cursor.com) or has known wire-format gaps
# (goose deeplinks omit the headers parameter, so Bearer auth doesn't
# survive — see github.com/block/goose#4006).
module Mcp
  module Connect
    class InstallAction
      extend T::Sig

      sig { params(harness_key: String, mcp_url: String, token: String, agent_handle: String).void }
      def initialize(harness_key:, mcp_url:, token:, agent_handle:)
        @harness_key = harness_key
        @mcp_url = mcp_url
        @token = token
        @agent_handle = agent_handle
      end

      # Server name as it appears in the harness's config. Scoped by agent
      # handle so a human principal can connect multiple agents to the same
      # harness without their configs colliding on a shared "harmonic" key.
      sig { returns(String) }
      def server_name
        "harmonic-#{@agent_handle}"
      end

      # Env-var-safe rendering of the server name (for Codex's
      # bearer_token_env_var). Handles are [a-zA-Z0-9_-], so we just upcase
      # and convert dashes to underscores.
      sig { returns(String) }
      def env_var_name
        "HARMONIC_MCP_TOKEN_#{@agent_handle.upcase.tr('-', '_')}"
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        case @harness_key
        when "cursor"         then cursor
        when "claude-code"    then claude_code
        when "claude-desktop" then claude_desktop
        when "codex"          then codex
        when "codex-cloud"    then credentials_block("/help/mcp/connect/codex-cloud")
        when "cline"          then cline
        when "continue"       then continue
        when "goose"          then goose
        when "hermes-agent"   then credentials_block("/help/mcp/connect/hermes-agent")
        when "openclaw"       then credentials_block("/help/mcp/connect/openclaw")
        else
          raise ArgumentError, "Unknown harness: #{@harness_key.inspect}"
        end
      end

      private

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def cursor
        # Snippet, not deeplink — the cursor.com install-mcp URL would
        # embed the Bearer token in a query string that transits cursor.com's
        # servers and lands in the user's browser history. The copy-paste
        # path keeps the token on the user's machine.
        config = JSON.pretty_generate({
          mcpServers: {
            server_name => {
              url: @mcp_url,
              headers: { "Authorization" => "Bearer #{@token}" },
            },
          },
        })
        {
          kind: :snippet,
          payload: {
            format: "json",
            code: config,
            paste_into: "Save this as ~/.cursor/mcp.json (macOS/Linux) or " \
                        "%USERPROFILE%\\.cursor\\mcp.json (Windows). If the file " \
                        "already exists, merge the #{server_name} entry into the existing " \
                        "mcpServers object. Cursor picks up changes within a second " \
                        "or two — no restart usually needed.",
          },
        }
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def claude_desktop
        # Claude Desktop's `type` field for streamable HTTP is "http"
        # (different from Cline's camelCase "streamableHttp"). The native
        # Custom Connector UI requires OAuth, so the config-file path is
        # the supported workaround for static Bearer tokens.
        config = JSON.pretty_generate({
          mcpServers: {
            server_name => {
              type: "http",
              url: @mcp_url,
              headers: { "Authorization" => "Bearer #{@token}" },
            },
          },
        })
        {
          kind: :snippet,
          payload: {
            format: "json",
            code: config,
            paste_into: "Edit ~/Library/Application Support/Claude/claude_desktop_config.json (macOS) " \
                        "or %APPDATA%\\Claude\\claude_desktop_config.json (Windows). Merge the " \
                        "#{server_name} entry into the existing mcpServers object, then restart Claude Desktop.",
          },
        }
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def claude_code
        cmd = %{claude mcp add --transport http #{server_name} #{@mcp_url} --header "Authorization: Bearer #{@token}"}
        {
          kind: :cli_command,
          payload: {
            blocks: [
              { label: "Run this in your terminal:", code: cmd, hint: nil },
            ],
          },
        }
      end

      # Codex covers the CLI, Desktop app, and IDE extension — they all
      # share `~/.codex/config.toml`, so a single `codex mcp add` is enough
      # to wire all three. (Codex Cloud at chatgpt.com/codex is a separate
      # UI-based connector flow, handled by the credentials shape.)
      sig { returns(T::Hash[Symbol, T.untyped]) }
      def codex
        {
          kind: :cli_command,
          payload: {
            blocks: [
              {
                label: "Set the token in your shell:",
                code: "export #{env_var_name}=#{@token}",
                hint: "Add this to your shell rc (~/.zshrc, ~/.bashrc) so it survives restarts.",
              },
              {
                label: "Add the MCP server:",
                code: "codex mcp add #{server_name} --url #{@mcp_url} --bearer-token-env-var #{env_var_name}",
                hint: "Wires up the CLI, Desktop app, and IDE extension at once — they share the same config.",
              },
            ],
          },
        }
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def cline
        config = JSON.pretty_generate({
          mcpServers: {
            server_name => {
              url: @mcp_url,
              type: "streamableHttp",
              headers: { "Authorization" => "Bearer #{@token}" },
              disabled: false,
              autoApprove: [],
            },
          },
        })
        {
          kind: :snippet,
          payload: {
            format: "json",
            code: config,
            paste_into: "Open Cline in VSCode → MCP Servers panel → Configure MCP Servers (JSON) and merge the #{server_name} entry into cline_mcp_settings.json.",
          },
        }
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def continue
        yaml = <<~YAML
          name: Harmonic MCP (#{@agent_handle})
          version: 0.0.1
          schema: v1
          mcpServers:
            - name: #{server_name}
              type: streamable-http
              url: #{@mcp_url}
              requestOptions:
                headers:
                  Authorization: Bearer #{@token}
        YAML
        {
          kind: :snippet,
          payload: {
            format: "yaml",
            code: yaml,
            paste_into: "Save this as .continue/mcpServers/#{server_name}.yaml in your workspace (Continue's MCP support is per-workspace).",
          },
        }
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def goose
        {
          kind: :snippet,
          payload: {
            format: "text",
            code: "Bearer #{@token}",
            paste_into: "Run `goose configure` → Add Extension → Remote Extension (Streamable HTTP). " \
                        "Name it #{server_name}, use URL #{@mcp_url}, and add a header named Authorization with the value above.",
          },
        }
      end

      sig { params(help_path: String).returns(T::Hash[Symbol, T.untyped]) }
      def credentials_block(help_path)
        {
          kind: :credentials,
          payload: {
            mcp_url: @mcp_url,
            token: @token,
            help_path: help_path,
          },
        }
      end
    end
  end
end
