class CreateUserLists < ActiveRecord::Migration[7.2]
  # rubocop:disable Metrics/MethodLength
  def change
    create_table :user_lists, id: :uuid do |t|
      t.references :tenant,     type: :uuid, null: false, foreign_key: true
      t.references :collective, type: :uuid, null: false, foreign_key: true
      t.references :creator,    type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :owner,      type: :uuid, null: false, foreign_key: { to_table: :users }

      t.string  :truncated_id,   null: false, as: "LEFT(id::text, 8)", stored: true
      t.string  :name,           null: false
      t.text    :description
      t.string  :visibility,     null: false, default: "public"
      t.boolean :is_primary,     null: false, default: false
      t.datetime :deleted_at
      t.uuid     :deleted_by_id

      t.timestamps
    end

    add_index :user_lists, :truncated_id, unique: true
    # One primary list per owner per tenant (across all collectives).
    add_index :user_lists,
              [:tenant_id, :owner_id],
              unique: true,
              where: "is_primary = TRUE AND deleted_at IS NULL",
              name: "index_user_lists_one_primary_per_owner_per_tenant"
    add_index :user_lists, [:collective_id, :visibility]
    add_index :user_lists, :deleted_at

    create_table :user_list_members, id: :uuid do |t|
      t.references :tenant,     type: :uuid, null: false, foreign_key: true
      t.references :collective, type: :uuid, null: false, foreign_key: true
      t.references :user_list,  type: :uuid, null: false, foreign_key: true
      t.references :user,       type: :uuid, null: false, foreign_key: true
      t.references :added_by,   type: :uuid, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :user_list_members, [:user_list_id, :user_id], unique: true,
                                                             name: "index_user_list_members_on_list_and_user"
    add_index :user_list_members, [:user_id, :collective_id],
              name: "index_user_list_members_on_user_and_collective"
  end
  # rubocop:enable Metrics/MethodLength
end
