class CreateStudios < ActiveRecord::Migration[7.0]
  def change
    create_table :studios, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :handle
      t.jsonb :settings, default: {}

      t.timestamps
    end
    add_index :studios, [:tenant_id, :handle], unique: true

    tables_to_update = ActiveRecord::Base.connection.tables - [
      'tenants', 'users', 'tenant_users', 'api_tokens', 'oauth_identities',
      'studios', 'studio_users', 'ar_internal_metadata', 'schema_migrations'
    ]
    tables_to_update.each do |table|
      add_reference table, :studio, null: true, foreign_key: true, type: :uuid
    end

    add_reference :tenants, :main_superagent, null: true, foreign_key: { to_table: :studios }, type: :uuid

    create_table :studio_users, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :studio, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.datetime :archived_at

      t.timestamps
    end
    add_index :studio_users, [:tenant_id, :studio_id, :user_id], unique: true

    # Comment out the following when rolling back
    Tenant.all.each do |tenant|
      tenant.create_main_superagent!
      tenant.tenant_users.each do |tu|
        tenant.main_superagent.add_user!(tu.user)
      end
      tables_to_update.each do |table|
        tenant.send(table).update_all(studio_id: tenant.main_superagent.id)
      end
    end
  end
end
