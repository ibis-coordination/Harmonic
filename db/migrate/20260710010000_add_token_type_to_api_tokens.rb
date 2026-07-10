class AddTokenTypeToApiTokens < ActiveRecord::Migration[7.2]
  # Formalizes mcp_only into three mutually exclusive token types:
  # rest (REST/markdown only), mcp (/mcp only), llm_gateway (the LLM
  # gateway only). Each token has exactly one purpose, fixed at creation.
  def up
    add_column :api_tokens, :token_type, :string

    execute "UPDATE api_tokens SET token_type = CASE WHEN mcp_only THEN 'mcp' ELSE 'rest' END"

    change_column_default :api_tokens, :token_type, "rest"
    change_column_null :api_tokens, :token_type, false

    # Internal agents cannot have user-issued API keys (they act only via the
    # agent-runner's ephemeral internal tokens): revoke any legacy ones.
    execute <<~SQL
      UPDATE api_tokens SET deleted_at = CURRENT_TIMESTAMP
      WHERE deleted_at IS NULL
        AND internal = FALSE
        AND user_id IN (
          SELECT id FROM users
          WHERE user_type = 'ai_agent'
            AND (system_role IS NOT NULL OR agent_configuration->>'mode' = 'internal')
        )
    SQL

    remove_column :api_tokens, :mcp_only
  end

  def down
    add_column :api_tokens, :mcp_only, :boolean, default: false, null: false
    execute "UPDATE api_tokens SET mcp_only = (token_type = 'mcp')"
    remove_column :api_tokens, :token_type
    # Tokens revoked by `up` stay revoked.
  end
end
