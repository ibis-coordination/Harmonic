class AddEmailChangeFieldsToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :pending_email, :string
    add_column :users, :email_confirmation_token, :string
    add_column :users, :email_confirmation_sent_at, :datetime
  end
end
