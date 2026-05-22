class AddPreviousEmailConfirmationTokenToOmniAuthIdentities < ActiveRecord::Migration[7.2]
  # Holds the immediately-prior token + its sent_at, so an in-flight email
  # (queued via deliver_later and not yet delivered) keeps working after a
  # subsequent send_email_confirmation! rotates the current slot. Without
  # this, the resend button (or a re-login auto-send) silently invalidates
  # any unclicked confirmation email, producing a 404 when the user clicks it.
  def up
    change_table :omni_auth_identities, bulk: true do |t|
      t.string :previous_email_confirmation_token
      t.timestamp :previous_email_confirmation_sent_at
    end

    # Lookup by token must hit either slot. Mirrors the existing
    # email_confirmation_token unique index (Postgres allows multiple NULLs in
    # a unique index, which is what we want here).
    add_index :omni_auth_identities, :previous_email_confirmation_token, unique: true
  end

  def down
    remove_index :omni_auth_identities, :previous_email_confirmation_token
    change_table :omni_auth_identities, bulk: true do |t|
      t.remove :previous_email_confirmation_sent_at
      t.remove :previous_email_confirmation_token
    end
  end
end
