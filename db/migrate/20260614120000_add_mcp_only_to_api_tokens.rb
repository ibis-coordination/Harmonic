class AddMcpOnlyToApiTokens < ActiveRecord::Migration[7.2]
  def change
    # false default = no breaking change. New agent tokens override at the application layer.
    add_column :api_tokens, :mcp_only, :boolean, null: false, default: false
  end
end
