class DropCustomDataRecords < ActiveRecord::Migration[7.0]
  def up
    drop_table :custom_data_history_events, if_exists: true
    drop_table :custom_data_associations, if_exists: true
    drop_table :custom_data_records, if_exists: true
    drop_table :custom_data_tables, if_exists: true
    drop_table :custom_data_configs, if_exists: true
  end

  def down
    create_table :custom_data_configs, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.jsonb :config, default: {}

      t.timestamps
    end

    create_table :custom_data_tables, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.jsonb :config, default: {}

      t.timestamps
    end
    add_index :custom_data_tables, [:tenant_id, :name], unique: true, name: 'index_custom_data_tables_on_tenant_and_name'

    create_table :custom_data_records, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :created_by, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.references :updated_by, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.references :table, null: false, foreign_key: { to_table: :custom_data_tables }, type: :uuid
      t.string :custom_uid, null: true
      t.jsonb :data, default: {}
      t.datetime :deleted_at

      t.timestamps
    end
    add_index :custom_data_records, [:tenant_id, :table_id], name: 'index_custom_data_on_ten_tab'
    add_index :custom_data_records, [:tenant_id, :table_id, :custom_uid], unique: true, name: 'index_custom_data_on_ten_tab_cuid'

    create_table :custom_data_associations, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :parent_record, null: false, foreign_key: { to_table: :custom_data_records }, type: :uuid
      t.references :child_record, null: false, foreign_key: { to_table: :custom_data_records }, type: :uuid

      t.timestamps
    end
    add_index :custom_data_associations, [:tenant_id, :parent_record_id], name: 'index_custom_data_associations_on_ten_par'
    add_index :custom_data_associations, [:tenant_id, :parent_record_id, :child_record_id], unique: true, name: 'index_custom_data_associations_on_ten_par_chi'

    create_table :custom_data_history_events, id: :uuid do |t|
      t.references :tenant, null: false, foreign_key: true, type: :uuid
      t.references :custom_data_record, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.datetime :happened_at, null: false
      t.string :event_type, null: false
      t.jsonb :event_data, default: {}

      t.timestamps
    end
    add_index :custom_data_history_events, [:tenant_id, :custom_data_record_id], name: 'index_custom_data_history_events_on_ten_cdr'

  end
end
