# typed: true

# Registry of MCP client harnesses supported by the Connect flow. Maps the
# URL slug (e.g. "claude-code") to a human-readable display name used as the
# token's `client_name` and as the label on settings UI.
module Mcp
  module Connect
    extend T::Sig

    # Ordered alphabetically by display name. The order propagates to the
    # agent settings Connect buttons and any UI that iterates HARNESSES.
    HARNESSES = T.let({
      "claude-code" => "Claude Code",
      "claude-desktop" => "Claude Desktop",
      "cline" => "Cline",
      "codex" => "Codex",
      "codex-cloud" => "Codex Cloud",
      "continue" => "Continue",
      "cursor" => "Cursor",
      "goose" => "Goose",
      "hermes-agent" => "Hermes Agent",
      "openclaw" => "OpenClaw",
    }.freeze, T::Hash[String, String])

    # Frozen map from harness key to its setup-guide template path. Derived
    # from HARNESSES so we can't drift, and the lookup keeps user input out
    # of render(template:) — Brakeman flags the interpolated form even when
    # an allowlist guard precedes it, so callers should treat a nil return
    # as "unknown harness" and 404.
    HELP_TEMPLATES = T.let(
      HARNESSES.keys.index_with { |k| "help/mcp_connect/#{k.tr("-", "_")}" }.freeze,
      T::Hash[String, String]
    )

    sig { params(key: T.nilable(String)).returns(T.nilable(String)) }
    def self.display_name(key)
      return nil if key.nil?

      HARNESSES[key]
    end

    sig { params(key: T.nilable(String)).returns(T.nilable(String)) }
    def self.help_template(key)
      return nil if key.nil?

      HELP_TEMPLATES[key]
    end
  end
end
