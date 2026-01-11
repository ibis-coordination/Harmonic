class CreateNotificationRecipients < ActiveRecord::Migration[7.0]
  def change
    create_table :notification_recipients, id: :uuid do |t|
      t.references :notification, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :channel, null: false, default: "in_app"
      t.string :status, null: false, default: "pending"
      t.datetime :read_at
      t.datetime :dismissed_at
      t.datetime :delivered_at

      t.timestamps
    end

    add_index :notification_recipients, :channel
    add_index :notification_recipients, :status
    add_index :notification_recipients, [:user_id, :status]
  end
end
