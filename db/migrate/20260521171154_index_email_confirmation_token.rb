class IndexEmailConfirmationToken < ActiveRecord::Migration[7.2]
  # Adds a unique index on the email_confirmation_token column so that
  # EmailConfirmationsController#confirm's `find_by_email_confirmation_token`
  # lookup doesn't scan the whole table on every confirm-link click. Matches
  # the existing pattern for reset_password_token (also a unique index).
  def change
    add_index :omni_auth_identities, :email_confirmation_token, unique: true
  end
end
