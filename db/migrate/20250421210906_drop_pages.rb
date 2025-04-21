class DropPages < ActiveRecord::Migration[7.0]
  def up
    drop_table :pages, if_exists: true
  end

  def down
    create_table :pages, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :studio, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :path, null: false
      t.string :title, null: false, default: ''
      t.text :markdown, null: false, default: ''
      t.text :html, null: false, default: ''
      t.boolean :published, null: false, default: false
      t.datetime :published_at
      t.datetime :archived_at
      t.jsonb :settings, default: {}

      t.timestamps
    end
    add_index :pages, [:tenant_id, :studio_id, :path], unique: true
  end
end
