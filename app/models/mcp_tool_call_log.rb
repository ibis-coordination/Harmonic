# typed: true

# Append-only audit log of every MCP tool call. No retention policy is in
# place yet — rows accumulate indefinitely. See
# `.claude/plans/mcp-audit-log-retention.md` for the eventual partition +
# cold-archive strategy. Track via row count; act before the table or its
# indexes affect insert latency.
class McpToolCallLog < ApplicationRecord
  # `unknown_tool` is distinct from `tool_error`: it means the agent invoked
  # a tool name the server doesn't know. A stream of these from one agent
  # usually points to a client/server version mismatch or model
  # hallucination, which calls for a different response than a real tool
  # failure.
  #
  # `pending` is the in-flight state — rows are created with this status at
  # the start of `tools/call` handling (so resource attribution rows can FK
  # against the id) and updated to a terminal status post-dispatch. A row
  # that stays `pending` indicates a process killed mid-dispatch.
  STATUSES = ["pending", "ok", "tool_error", "unknown_tool"].freeze

  belongs_to :tenant
  belongs_to :user
  belongs_to :api_token
  # Set when the token's polymorphic context is an AiAgentTaskRun — i.e. the
  # call came from an internal agent runner ephemeral token (or, post-runner-
  # migration, from any internal agent routing through /mcp). Null for
  # external MCP clients (Claude Desktop / Code / Cursor / etc.).
  belongs_to :ai_agent_task_run, optional: true

  has_many :mcp_tool_call_resources, dependent: :destroy

  validates :tool_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :duration_ms, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
