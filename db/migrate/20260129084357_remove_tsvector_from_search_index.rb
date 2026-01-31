# typed: false

class RemoveTsvectorFromSearchIndex < ActiveRecord::Migration[7.0]
  def up
    # Remove the GIN index on the tsvector column
    execute "DROP INDEX IF EXISTS idx_search_index_fulltext"

    # Remove the generated tsvector column (no longer needed with pg_trgm)
    remove_column :search_index, :searchable_tsvector
  end

  def down
    # Re-add the generated tsvector column
    execute <<~SQL
      ALTER TABLE search_index
      ADD COLUMN searchable_tsvector tsvector
      GENERATED ALWAYS AS (to_tsvector('english', searchable_text)) STORED;

      CREATE INDEX idx_search_index_fulltext
      ON search_index USING GIN (searchable_tsvector);
    SQL
  end
end
