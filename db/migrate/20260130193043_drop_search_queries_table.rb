# typed: false

# Drop the unused search_queries table.
#
# This table was created as placeholder for search analytics but was never implemented.
# It can be recreated later if/when search analytics are needed.
#
class DropSearchQueriesTable < ActiveRecord::Migration[7.0]
  def up
    drop_table :search_queries
  end

  def down
    create_table :search_queries, id: :uuid do |t|
      t.uuid :tenant_id, null: false
      t.uuid :superagent_id
      t.uuid :user_id

      t.text :query_text
      t.jsonb :filters
      t.string :sort_by
      t.string :group_by

      t.integer :result_count
      t.string :cursor

      t.uuid :clicked_item_id
      t.datetime :clicked_at

      t.datetime :executed_at, default: -> { "NOW()" }
      t.integer :duration_ms

      t.string :session_id

      t.index [:tenant_id, :executed_at], name: "idx_search_queries_tenant_time"
    end
  end
end
