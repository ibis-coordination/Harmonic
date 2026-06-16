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

      sig { params(harness_key: String, mcp_url: String, token: String).void }
      def initialize(harness_key:, mcp_url:, token:)
        @harness_key = harness_key
        @mcp_url = mcp_url
        @token = token
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h
        case @harness_key
        when "cursor"        then cursor
        when "claude-code"   then claude_code
        when "codex-cli"     then codex_cli
        when "cline"         then cline
        when "continue"      then continue
        when "goose"         then goose
        when "hermes-agent" then credentials_block("/help/mcp/connect/hermes-agent")
        when "openclaw"      then credentials_block("/help/mcp/connect/openclaw")
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
            harmonic: {
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
                        "already exists, merge the harmonic entry into the existing " \
                        "mcpServers object. Cursor picks up changes within a second " \
                        "or two — no restart usually needed.",
          },
        }
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def claude_code
        cmd = %{claude mcp add --transport http harmonic #{@mcp_url} --header "Authorization: Bearer #{@token}"}
        {
          kind: :cli_command,
          payload: {
            blocks: [
              { label: "Run this in your terminal:", code: cmd, hint: nil },
            ],
          },
        }
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def codex_cli
        {
          kind: :cli_command,
          payload: {
            blocks: [
              {
                label: "Set the token in your shell:",
                code: "export HARMONIC_MCP_TOKEN=#{@token}",
                hint: "Add this to your shell rc (~/.zshrc, ~/.bashrc) so it survives restarts.",
              },
              {
                label: "Add the MCP server:",
                code: "codex mcp add harmonic --url #{@mcp_url} --bearer-token-env-var HARMONIC_MCP_TOKEN",
                hint: nil,
              },
              {
                label: "Enable HTTP transport in ~/.codex/config.toml:",
                code: "experimental_use_rmcp_client = true",
                hint: "This goes at the top of the file, not inside [mcp_servers.*].",
              },
            ],
          },
        }
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def cline
        config = JSON.pretty_generate({
          mcpServers: {
            harmonic: {
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
            paste_into: "Open Cline in VSCode → MCP Servers panel → Configure MCP Servers (JSON) and merge this into cline_mcp_settings.json.",
          },
        }
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def continue
        yaml = <<~YAML
          name: Harmonic MCP
          version: 0.0.1
          schema: v1
          mcpServers:
            - name: Harmonic
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
            paste_into: "Save this as .continue/mcpServers/harmonic.yaml in your workspace (Continue's MCP support is per-workspace).",
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
                        "Use URL #{@mcp_url} and add a header named Authorization with the value above.",
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
