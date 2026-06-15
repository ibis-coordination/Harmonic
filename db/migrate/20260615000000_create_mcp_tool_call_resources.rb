class CreateMcpToolCallResources < ActiveRecord::Migration[7.2]
  def change
    create_table :mcp_tool_call_resources, id: :uuid do |t|
      # Suppress single-column tenant_id index; the compound (tenant_id, created_at)
      # below covers equality lookups on the leading column. This table grows
      # alongside mcp_tool_call_logs, so extra index overhead on each insert matters.
      t.references :tenant, null: false, foreign_key: true, type: :uuid, index: false
      t.references :mcp_tool_call_log, null: false, foreign_key: true, type: :uuid, index: false
      # Polymorphic resource — the touched record. Joint index below.
      t.references :resource, null: false, polymorphic: true, type: :uuid, index: false
      # Resource's home collective (may differ from request's current collective).
      # Required: every attributable Harmonic resource type has a collective.
      t.references :resource_collective, null: false, foreign_key: { to_table: :collectives }, type: :uuid
      # Literal action name as invoked via execute_action (create_note, confirm_read, etc.).
      t.string :action_name, null: false
      # Precomputed display URL; mirrors AiAgentTaskRunResource.display_path.
      t.string :display_path
      t.timestamps
    end

    add_index :mcp_tool_call_resources, [:tenant_id, :created_at]
    add_index :mcp_tool_call_resources, [:mcp_tool_call_log_id, :created_at]
    add_index :mcp_tool_call_resources, [:resource_type, :resource_id],
              name: "idx_mcp_tool_call_resources_on_resource"
    add_index :mcp_tool_call_resources, [:mcp_tool_call_log_id, :resource_id, :resource_type],
              unique: true,
              name: "idx_mcp_tool_call_resources_unique"
  end
end
