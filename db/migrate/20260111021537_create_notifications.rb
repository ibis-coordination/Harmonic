class CreateNotifications < ActiveRecord::Migration[7.0]
  def change
    create_table :notifications, id: :uuid do |t|
      t.references :event, null: false, foreign_key: true, type: :uuid
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.string :notification_type, null: false
      t.string :title, null: false
      t.text :body
      t.string :url

      t.timestamps
    end

    add_index :notifications, :notification_type
    add_index :notifications, :created_at
  end
end
