# typed: true

# Append-only audit log of every MCP tool call. No retention policy is in
# place yet — rows accumulate indefinitely. At 60 calls/min/token × 100
# active tokens that's ~8.6M rows/day, so this needs a retention or
# archiving strategy (time-based deletion, partitioning + drop-old, or
# offload to cold storage) before production traffic grows past a few
# thousand tokens. Track via row count; act before the table or its
# indexes affect insert latency.
class McpToolCallLog < ApplicationRecord
  # `unknown_tool` is distinct from `tool_error`: it means the agent invoked
  # a tool name the server doesn't know. A stream of these from one agent
  # usually points to a client/server version mismatch or model
  # hallucination, which calls for a different response than a real tool
  # failure.
  STATUSES = ["ok", "tool_error", "unknown_tool"].freeze

  belongs_to :tenant
  belongs_to :user
  belongs_to :api_token

  validates :tool_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :duration_ms, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
