class CreateWebPushSubscriptions < ActiveRecord::Migration[7.2]
  def change
    # Deliberately no tenant_id: a push subscription is a user's device
    # registration, valid across every tenant they belong to (like
    # refresh_tokens). ApplicationRecord's default scope keys off column
    # presence, so omitting the column is what makes the model user-global.
    create_table :web_push_subscriptions, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :endpoint, null: false
      t.string :p256dh_key, null: false
      t.string :auth_key, null: false
      t.string :user_agent
      t.string :device_label
      t.datetime :last_seen_at, null: false
      t.datetime :revoked_at
      t.string :revoked_reason
      t.datetime :last_error_at
      t.string :last_error
      t.timestamps
    end

    add_index :web_push_subscriptions, [:user_id, :endpoint], unique: true
  end
end
