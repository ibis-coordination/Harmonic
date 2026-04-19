class AddUserIdToOmniAuthIdentities < ActiveRecord::Migration[7.2]
  def up
    # Add nullable column (nullable because OmniAuth Identity registration creates
    # the record before a User exists — user_id is backfilled in the callback)
    add_reference :omni_auth_identities, :user, type: :uuid, null: true, foreign_key: true, index: false

    # Backfill from matching emails
    execute <<~SQL
      UPDATE omni_auth_identities
      SET user_id = users.id
      FROM users
      WHERE users.email = omni_auth_identities.email
    SQL

    # Add unique index (one identity per user, NULLs allowed for registration-in-progress)
    add_index :omni_auth_identities, :user_id, unique: true
  end

  def down
    remove_reference :omni_auth_identities, :user
  end
end
