# typed: true

# Registry of MCP client harnesses supported by the Connect flow. Maps the
# URL slug (e.g. "claude-code") to a human-readable display name used as the
# token's `client_name` and as the label on settings UI.
module Mcp
  module Connect
    extend T::Sig

    HARNESSES = T.let({
      "cursor" => "Cursor",
      "claude-code" => "Claude Code",
      "codex-cli" => "Codex CLI",
      "cline" => "Cline",
      "continue" => "Continue",
      "goose" => "Goose",
      "hermes-agent" => "Hermes Agent",
      "openclaw" => "OpenClaw",
    }.freeze, T::Hash[String, String])

    sig { params(key: T.nilable(String)).returns(T.nilable(String)) }
    def self.display_name(key)
      return nil if key.nil?
      HARNESSES[key]
    end

    sig { params(key: T.nilable(String)).returns(T::Boolean) }
    def self.supported?(key)
      return false if key.nil?
      HARNESSES.key?(key)
    end
  end
end
