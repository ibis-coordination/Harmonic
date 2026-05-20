class AddEmailConfirmationToOmniAuthIdentities < ActiveRecord::Migration[7.2]
  def up
    add_column :omni_auth_identities, :email_confirmed_at, :timestamp
    add_column :omni_auth_identities, :email_confirmation_token, :string
    add_column :omni_auth_identities, :email_confirmation_sent_at, :timestamp

    # Backfill: any identity linked to a User that has an OAuth identity is
    # implicitly verified — Google/GitHub asserts the email. Email/password-only
    # identities stay unverified and will be prompted to confirm via the
    # activation gate on their next request.
    execute <<~SQL.squish
      UPDATE omni_auth_identities
      SET email_confirmed_at = COALESCE(omni_auth_identities.created_at, NOW())
      WHERE user_id IN (
        SELECT user_id FROM oauth_identities WHERE provider != 'identity'
      )
    SQL
  end

  def down
    remove_column :omni_auth_identities, :email_confirmation_sent_at
    remove_column :omni_auth_identities, :email_confirmation_token
    remove_column :omni_auth_identities, :email_confirmed_at
  end
end
