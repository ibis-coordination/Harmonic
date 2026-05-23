# typed: true

class CreateMediaItems < ActiveRecord::Migration[7.2]
  def change
    create_table :media_items, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :collective, type: :uuid, null: false, foreign_key: true
      t.references :mediable, polymorphic: true, null: false, type: :uuid
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.string :alt_text
      t.text :caption
      t.integer :display_order, null: false, default: 0
      t.integer :width
      t.integer :height
      t.references :created_by, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :updated_by, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :media_items,
              [:mediable_type, :mediable_id, :display_order],
              name: "index_media_items_on_mediable_and_order"
    add_index :media_items, [:tenant_id, :collective_id]
  end
end
