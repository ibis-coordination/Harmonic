# typed: false

class HashApiTokens < ActiveRecord::Migration[7.0]
  def up
    # Add new columns for hashed tokens
    add_column :api_tokens, :token_hash, :string
    add_column :api_tokens, :token_prefix, :string, limit: 4

    # Migrate existing tokens: hash them and store prefix
    ApiToken.unscoped.find_each do |api_token|
      next if api_token.token.blank?

      api_token.update_columns(
        token_hash: Digest::SHA256.hexdigest(api_token.token),
        token_prefix: api_token.token[0..3],
      )
    end

    # Remove old plaintext token column and its index
    remove_index :api_tokens, :token, if_exists: true
    remove_column :api_tokens, :token

    # Add index on token_hash for fast lookups
    add_index :api_tokens, :token_hash, unique: true
  end

  def down
    # Add back the plaintext token column
    add_column :api_tokens, :token, :string

    # Note: We cannot restore the original tokens since they were hashed (one-way)
    # Tokens will need to be regenerated

    # Remove new columns
    remove_index :api_tokens, :token_hash, if_exists: true
    remove_column :api_tokens, :token_hash
    remove_column :api_tokens, :token_prefix
  end
end
