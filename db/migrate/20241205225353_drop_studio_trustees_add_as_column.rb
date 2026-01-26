class DropStudioTrusteesAddAsColumn < ActiveRecord::Migration[7.0]
  def up
    add_column :studios, :trustee_user_id, :uuid, null: true, foreign_key: { to_table: :users }
    # Migrate existing studio trustees to column
    execute <<-SQL
      UPDATE studios
      SET trustee_user_id = studio_trustees.trustee_user_id
      FROM studio_trustees
      WHERE studios.id = studio_trustees.studio_id
    SQL
    drop_table :studio_trustees
  end

  def down
    create_table :studio_trustees, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :studio, null: false, foreign_key: true, type: :uuid
      t.references :trustee_user, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.jsonb :settings, default: {}
      t.timestamps
    end
    add_index :studio_trustees, [:tenant_id, :studio_id, :trustee_user_id], unique: true, name: 'studio_trustees_unique_index'
    # Migrate trustee_user_id back to studio_trustees table
    execute <<-SQL
      INSERT INTO studio_trustees (id, tenant_id, studio_id, trustee_user_id, settings, created_at, updated_at)
      SELECT gen_random_uuid(), tenant_id, id, trustee_user_id, '{}', NOW(), NOW()
      FROM studios
      WHERE trustee_user_id IS NOT NULL
    SQL
    remove_column :studios, :trustee_user_id
  end
end
