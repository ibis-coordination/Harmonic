class AddPasswordResetToOmniAuthIdentities < ActiveRecord::Migration[7.0]
  def change
    add_column :omni_auth_identities, :reset_password_token, :string
    add_column :omni_auth_identities, :reset_password_sent_at, :datetime
    add_index :omni_auth_identities, :reset_password_token, unique: true
  end
end
