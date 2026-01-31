# typed: false

# rubocop:disable Metrics/MethodLength, Rails/SquishedSQLHeredocs

# Partition search_index table by tenant_id for better performance at scale.
#
# Hash partitioning distributes data across 16 partitions based on tenant_id hash.
# Since all search queries are scoped by tenant_id, PostgreSQL can prune partitions
# and only scan the relevant one.
#
# Benefits:
# - Partition pruning: queries only scan one partition
# - Parallel maintenance: VACUUM/ANALYZE can run on individual partitions
# - Better cache utilization: working set per tenant fits in memory
# - Easier scaling: can increase partitions later if needed
#
class PartitionSearchIndexByTenant < ActiveRecord::Migration[7.0]
  def up
    # Step 1: Create new partitioned table with same structure
    execute <<~SQL
      CREATE TABLE search_index_partitioned (
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        tenant_id uuid NOT NULL,
        superagent_id uuid NOT NULL,
        item_type character varying NOT NULL,
        item_id uuid NOT NULL,
        truncated_id character varying(8) NOT NULL,
        title text NOT NULL,
        body text,
        searchable_text text NOT NULL,
        created_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL,
        deadline timestamp(6) without time zone NOT NULL,
        created_by_id uuid,
        updated_by_id uuid,
        link_count integer DEFAULT 0,
        backlink_count integer DEFAULT 0,
        participant_count integer DEFAULT 0,
        voter_count integer DEFAULT 0,
        option_count integer DEFAULT 0,
        comment_count integer DEFAULT 0,
        reader_count integer DEFAULT 0,
        is_pinned boolean DEFAULT false,
        sort_key bigint NOT NULL DEFAULT nextval('search_index_sort_key_seq'::regclass)
      ) PARTITION BY HASH (tenant_id);
    SQL

    # Step 2: Create 16 hash partitions
    16.times do |i|
      execute <<~SQL
        CREATE TABLE search_index_p#{i} PARTITION OF search_index_partitioned
        FOR VALUES WITH (MODULUS 16, REMAINDER #{i});
      SQL
    end

    # Step 3: Create indexes on the partitioned table
    # PostgreSQL will automatically create these on each partition
    execute <<~SQL
      -- Primary key (must include partition key)
      ALTER TABLE search_index_partitioned ADD PRIMARY KEY (tenant_id, id);

      -- Unique constraint for upsert operations
      CREATE UNIQUE INDEX idx_search_index_part_unique_item
      ON search_index_partitioned (tenant_id, item_type, item_id);

      -- Index for looking up by item (used by ReindexSearchJob)
      CREATE INDEX idx_search_index_part_item
      ON search_index_partitioned (item_type, item_id);

      -- Index for tenant + superagent scoping
      CREATE INDEX idx_search_index_part_tenant_superagent
      ON search_index_partitioned (tenant_id, superagent_id);

      -- Index for sorting by created_at
      CREATE INDEX idx_search_index_part_created
      ON search_index_partitioned (tenant_id, superagent_id, created_at DESC);

      -- Index for sorting by deadline
      CREATE INDEX idx_search_index_part_deadline
      ON search_index_partitioned (tenant_id, superagent_id, deadline);

      -- Index for cursor-based pagination
      CREATE INDEX idx_search_index_part_cursor
      ON search_index_partitioned (tenant_id, superagent_id, sort_key DESC);

      -- GIN index for trigram search
      CREATE INDEX idx_search_index_part_trigram
      ON search_index_partitioned USING GIN (searchable_text gin_trgm_ops);

      -- Composite index for type-filtered queries (common pattern)
      CREATE INDEX idx_search_index_part_type
      ON search_index_partitioned (tenant_id, superagent_id, item_type);
    SQL

    # Step 4: Copy data from old table to new partitioned table
    execute <<~SQL
      INSERT INTO search_index_partitioned (
        id, tenant_id, superagent_id, item_type, item_id, truncated_id,
        title, body, searchable_text, created_at, updated_at, deadline,
        created_by_id, updated_by_id, link_count, backlink_count,
        participant_count, voter_count, option_count, comment_count,
        reader_count, is_pinned, sort_key
      )
      SELECT
        id, tenant_id, superagent_id, item_type, item_id, truncated_id,
        title, body, searchable_text, created_at, updated_at, deadline,
        created_by_id, updated_by_id, link_count, backlink_count,
        participant_count, voter_count, option_count, comment_count,
        reader_count, is_pinned, sort_key
      FROM search_index;
    SQL

    # Step 5: Swap tables
    execute <<~SQL
      -- Detach sequence from old table so we can drop it
      -- The sequence is shared with the new partitioned table
      ALTER SEQUENCE search_index_sort_key_seq OWNED BY NONE;

      -- Drop old table
      DROP TABLE search_index;

      -- Rename partitioned table to original name
      ALTER TABLE search_index_partitioned RENAME TO search_index;

      -- Rename indexes to match original naming convention
      ALTER INDEX idx_search_index_part_unique_item RENAME TO idx_search_index_unique_item;
      ALTER INDEX idx_search_index_part_item RENAME TO idx_search_index_item;
      ALTER INDEX idx_search_index_part_tenant_superagent RENAME TO idx_search_index_tenant_superagent;
      ALTER INDEX idx_search_index_part_created RENAME TO idx_search_index_created;
      ALTER INDEX idx_search_index_part_deadline RENAME TO idx_search_index_deadline;
      ALTER INDEX idx_search_index_part_cursor RENAME TO idx_search_index_cursor;
      ALTER INDEX idx_search_index_part_trigram RENAME TO idx_search_index_trigram;
      ALTER INDEX idx_search_index_part_type RENAME TO idx_search_index_type;

      -- Re-attach sequence to the new table
      ALTER SEQUENCE search_index_sort_key_seq OWNED BY search_index.sort_key;
    SQL
  end

  def down
    # Reverse: create non-partitioned table and migrate data back
    execute <<~SQL
      CREATE TABLE search_index_unpartitioned (
        id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
        tenant_id uuid NOT NULL,
        superagent_id uuid NOT NULL,
        item_type character varying NOT NULL,
        item_id uuid NOT NULL,
        truncated_id character varying(8) NOT NULL,
        title text NOT NULL,
        body text,
        searchable_text text NOT NULL,
        created_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL,
        deadline timestamp(6) without time zone NOT NULL,
        created_by_id uuid,
        updated_by_id uuid,
        link_count integer DEFAULT 0,
        backlink_count integer DEFAULT 0,
        participant_count integer DEFAULT 0,
        voter_count integer DEFAULT 0,
        option_count integer DEFAULT 0,
        comment_count integer DEFAULT 0,
        reader_count integer DEFAULT 0,
        is_pinned boolean DEFAULT false,
        sort_key bigint NOT NULL DEFAULT nextval('search_index_sort_key_seq'::regclass)
      );

      -- Copy data
      INSERT INTO search_index_unpartitioned
      SELECT * FROM search_index;

      -- Drop partitioned table (cascades to partitions)
      DROP TABLE search_index;

      -- Rename
      ALTER TABLE search_index_unpartitioned RENAME TO search_index;

      -- Recreate indexes
      CREATE UNIQUE INDEX idx_search_index_unique_item ON search_index (tenant_id, item_type, item_id);
      CREATE INDEX idx_search_index_item ON search_index (item_type, item_id);
      CREATE INDEX idx_search_index_tenant_superagent ON search_index (tenant_id, superagent_id);
      CREATE INDEX idx_search_index_created ON search_index (tenant_id, superagent_id, created_at DESC);
      CREATE INDEX idx_search_index_deadline ON search_index (tenant_id, superagent_id, deadline);
      CREATE INDEX idx_search_index_cursor ON search_index (tenant_id, superagent_id, sort_key DESC);
      CREATE INDEX idx_search_index_trigram ON search_index USING GIN (searchable_text gin_trgm_ops);
    SQL
  end
end
# rubocop:enable Metrics/MethodLength, Rails/SquishedSQLHeredocs
