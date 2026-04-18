class AddLastOtpAtToOmniAuthIdentities < ActiveRecord::Migration[7.2]
  def change
    add_column :omni_auth_identities, :last_otp_at, :integer
  end
end
