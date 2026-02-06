# frozen_string_literal: true

# Remove internal_encrypted_token column from api_tokens.
#
# Internal tokens are now ephemeral - created at run start and deleted at run end.
# The encrypted storage is no longer needed since tokens don't persist between runs.
class RemoveInternalEncryptedTokenFromApiTokens < ActiveRecord::Migration[7.0]
  def change
    remove_column :api_tokens, :internal_encrypted_token, :text
  end
end
