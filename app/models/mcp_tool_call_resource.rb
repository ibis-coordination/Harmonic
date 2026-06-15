# typed: true

# Per-call resource attribution for MCP tool calls.
#
# Each row links a touched resource (Note, Decision, etc.) to the
# McpToolCallLog row representing the call that touched it. Companion
# to McpToolCallLog at the per-resource grain.
#
# Coexists with AiAgentTaskRunResource during the agent-runner migration
# dual-write window. See .claude/plans/mcp-resource-attribution.md.
class McpToolCallResource < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :mcp_tool_call_log
  belongs_to :resource, polymorphic: true
  belongs_to :resource_collective, class_name: "Collective"

  validates :action_name, presence: true
  validate :resource_collective_matches_resource

  # Override default scope - this model is NOT scoped by collective_id since
  # resources may belong to different collectives than where the call originated.
  def self.default_scope
    where(tenant_id: Tenant.current_id)
  end

  # Return the stored value of the `display_path` column.
  # ApplicationRecord defines `display_path` as a fallback that returns `path`,
  # which assumes the model has a `collective` and `path_prefix`. This model
  # doesn't — the precomputed URL lives in the column of the same name.
  sig { returns(T.nilable(String)) }
  def display_path
    self[:display_path]
  end

  # Find attribution rows referencing a given resource.
  sig { params(record: T.untyped).returns(T.untyped) }
  def self.for_resource(record)
    return none unless record.respond_to?(:id) && record.respond_to?(:class)

    where(resource_type: record.class.name, resource_id: record.id)
  end

  private

  sig { void }
  def set_tenant_id
    return if tenant_id.present?

    self.tenant_id = T.must(mcp_tool_call_log&.tenant_id || Tenant.current_id)
  end

  sig { void }
  def resource_collective_matches_resource
    return if resource.blank?
    return unless resource.respond_to?(:collective_id)
    return if resource_collective_id == T.unsafe(resource).collective_id

    errors.add(:resource_collective, "must match resource's collective")
  end
end
