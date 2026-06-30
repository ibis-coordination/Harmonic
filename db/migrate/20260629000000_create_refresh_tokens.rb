class CreateRefreshTokens < ActiveRecord::Migration[7.2]
  def change
    create_table :refresh_tokens, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :token_digest, null: false
      t.uuid :family_id, null: false
      t.datetime :expires_at, null: false
      t.datetime :rotated_at
      t.datetime :last_used_at, null: false
      t.datetime :revoked_at
      t.string :revoked_reason
      t.string :user_agent
      t.string :device_label
      t.string :ip_at_issue
      t.datetime :two_factor_at
      t.timestamps
    end

    add_index :refresh_tokens, :token_digest, unique: true
    add_index :refresh_tokens, :family_id
    add_index :refresh_tokens, [:user_id, :revoked_at]
  end
end
