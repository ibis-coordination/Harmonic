# typed: false

class AddTrigramSearch < ActiveRecord::Migration[7.0]
  def change
    enable_extension "pg_trgm"

    # GIN index for trigram similarity search on searchable_text
    execute <<~SQL
      CREATE INDEX idx_search_index_trigram
      ON search_index USING GIN (searchable_text gin_trgm_ops);
    SQL
  end
end
