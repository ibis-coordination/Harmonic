class CreateContentReports < ActiveRecord::Migration[7.2]
  def change
    create_table :content_reports, id: :uuid do |t|
      t.references :reporter, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :reportable_type, null: false
      t.uuid :reportable_id, null: false
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.string :reason, null: false
      t.text :description
      t.string :status, null: false, default: "pending"
      t.references :reviewed_by, type: :uuid, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.text :admin_notes

      t.timestamps
    end

    add_index :content_reports, [:tenant_id, :status]
    add_index :content_reports, [:reportable_type, :reportable_id]
    add_index :content_reports, [:reporter_id, :reportable_type, :reportable_id, :tenant_id],
              unique: true, name: "index_content_reports_unique_per_reporter_and_reportable"
  end
end
