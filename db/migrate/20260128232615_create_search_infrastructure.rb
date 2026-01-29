# typed: false

class CreateSearchInfrastructure < ActiveRecord::Migration[7.0]
  def change
    # Table 1: search_index - Pre-computed, denormalized search table
    create_table :search_index, id: :uuid do |t|
      t.uuid :tenant_id, null: false
      t.uuid :superagent_id, null: false
      t.string :item_type, null: false
      t.uuid :item_id, null: false
      t.string :truncated_id, limit: 8, null: false

      t.text :title, null: false
      t.text :body
      t.text :searchable_text, null: false

      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
      t.datetime :deadline, null: false
      t.uuid :created_by_id
      t.uuid :updated_by_id

      t.integer :link_count, default: 0
      t.integer :backlink_count, default: 0
      t.integer :participant_count, default: 0
      t.integer :voter_count, default: 0
      t.integer :option_count, default: 0
      t.integer :comment_count, default: 0

      t.boolean :is_pinned, default: false

      t.index [:tenant_id, :superagent_id], name: "idx_search_index_tenant_superagent"
      t.index [:tenant_id, :item_type, :item_id], unique: true, name: "idx_search_index_unique_item"
      t.index [:item_type, :item_id], name: "idx_search_index_item"
    end

    # Add generated columns and indexes via raw SQL
    execute <<~SQL
      -- Generated tsvector column for full-text search
      ALTER TABLE search_index
      ADD COLUMN searchable_tsvector tsvector
      GENERATED ALWAYS AS (to_tsvector('english', searchable_text)) STORED;

      -- sort_key for cursor-based pagination (auto-incrementing)
      ALTER TABLE search_index
      ADD COLUMN sort_key bigserial;

      -- GIN index for full-text search
      CREATE INDEX idx_search_index_fulltext
      ON search_index USING GIN (searchable_tsvector);

      -- Index for sorting by created_at
      CREATE INDEX idx_search_index_created
      ON search_index (tenant_id, superagent_id, created_at DESC);

      -- Index for sorting by deadline
      CREATE INDEX idx_search_index_deadline
      ON search_index (tenant_id, superagent_id, deadline);

      -- Index for cursor-based pagination
      CREATE INDEX idx_search_index_cursor
      ON search_index (tenant_id, superagent_id, sort_key DESC);
    SQL

    # Table 2: user_item_status - Pre-computed user-item relationships
    create_table :user_item_status, id: :uuid do |t|
      t.uuid :tenant_id, null: false
      t.uuid :user_id, null: false
      t.string :item_type, null: false
      t.uuid :item_id, null: false

      t.boolean :has_read, default: false
      t.datetime :read_at
      t.boolean :has_voted, default: false
      t.datetime :voted_at
      t.boolean :is_participating, default: false
      t.datetime :participated_at
      t.boolean :is_creator, default: false
      t.datetime :last_viewed_at
      t.boolean :is_mentioned, default: false

      t.index [:tenant_id, :user_id], name: "idx_user_item_status_tenant_user"
      t.index [:tenant_id, :user_id, :item_type, :item_id], unique: true, name: "idx_user_item_status_unique"
    end

    # Partial indexes for common filter patterns
    execute <<~SQL
      CREATE INDEX idx_user_item_status_unread
      ON user_item_status (tenant_id, user_id, item_type)
      WHERE has_read = false;

      CREATE INDEX idx_user_item_status_not_voted
      ON user_item_status (tenant_id, user_id, item_type)
      WHERE has_voted = false;

      CREATE INDEX idx_user_item_status_not_participating
      ON user_item_status (tenant_id, user_id, item_type)
      WHERE is_participating = false;
    SQL

    # Table 3: search_queries - Analytics for search behavior
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
