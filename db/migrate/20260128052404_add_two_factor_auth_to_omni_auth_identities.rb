class AddTwoFactorAuthToOmniAuthIdentities < ActiveRecord::Migration[7.0]
  def change
    add_column :omni_auth_identities, :otp_secret, :string
    add_column :omni_auth_identities, :otp_enabled, :boolean, default: false, null: false
    add_column :omni_auth_identities, :otp_enabled_at, :datetime
    add_column :omni_auth_identities, :otp_recovery_codes, :jsonb, default: []
    add_column :omni_auth_identities, :otp_failed_attempts, :integer, default: 0, null: false
    add_column :omni_auth_identities, :otp_locked_until, :datetime
  end
end
