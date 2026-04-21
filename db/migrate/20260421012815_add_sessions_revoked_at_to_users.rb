class AddSessionsRevokedAtToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :sessions_revoked_at, :datetime
  end
end
