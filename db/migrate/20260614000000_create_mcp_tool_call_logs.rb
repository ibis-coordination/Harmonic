class CreateMcpToolCallLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :mcp_tool_call_logs, id: :uuid do |t|
      # Suppress single-column tenant_id / user_id indexes; the compound
      # (tenant_id, created_at) / (user_id, created_at) indexes below cover
      # equality lookups on the leading column. This table is append-only and
      # will grow fast, so extra index overhead on each insert matters.
      t.references :tenant, null: false, foreign_key: true, type: :uuid, index: false
      t.references :user, null: false, foreign_key: true, type: :uuid, index: false
      t.references :api_token, null: false, foreign_key: true, type: :uuid
      t.string :tool_name, null: false
      t.jsonb :arguments, null: false, default: {}
      t.string :status, null: false
      t.integer :duration_ms, null: false
      t.string :request_id
      t.timestamps
    end

    add_index :mcp_tool_call_logs, [:tenant_id, :created_at]
    add_index :mcp_tool_call_logs, [:user_id, :created_at]
  end
end
