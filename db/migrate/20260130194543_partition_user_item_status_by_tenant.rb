# typed: false

# rubocop:disable Metrics/MethodLength, Rails/SquishedSQLHeredocs

# Partition user_item_status table by tenant_id for better performance at scale.
#
# Hash partitioning distributes data across 16 partitions based on tenant_id hash.
# Since all user status queries are scoped by tenant_id, PostgreSQL can prune partitions
# and only scan the relevant one.
#
# Benefits:
# - Partition pruning: queries only scan one partition
# - Parallel maintenance: VACUUM/ANALYZE can run on individual partitions
# - Better cache utilization: working set per tenant fits in memory
# - Easier scaling: can increase partitions later if needed
#
class PartitionUserItemStatusByTenant < ActiveRecord::Migration[7.0]
  def up
    # Step 1: Create new partitioned table with same structure
    execute <<~SQL
      CREATE TABLE user_item_status_partitioned (
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        tenant_id uuid NOT NULL,
        user_id uuid NOT NULL,
        item_type character varying NOT NULL,
        item_id uuid NOT NULL,
        has_read boolean DEFAULT false,
        read_at timestamp(6) without time zone,
        has_voted boolean DEFAULT false,
        voted_at timestamp(6) without time zone,
        is_participating boolean DEFAULT false,
        participated_at timestamp(6) without time zone,
        is_creator boolean DEFAULT false,
        last_viewed_at timestamp(6) without time zone,
        is_mentioned boolean DEFAULT false
      ) PARTITION BY HASH (tenant_id);
    SQL

    # Step 2: Create 16 hash partitions
    16.times do |i|
      execute <<~SQL
        CREATE TABLE user_item_status_p#{i} PARTITION OF user_item_status_partitioned
        FOR VALUES WITH (MODULUS 16, REMAINDER #{i});
      SQL
    end

    # Step 3: Create indexes on the partitioned table
    # PostgreSQL will automatically create these on each partition
    execute <<~SQL
      -- Primary key (must include partition key)
      ALTER TABLE user_item_status_partitioned ADD PRIMARY KEY (tenant_id, id);

      -- Unique constraint for upsert operations
      CREATE UNIQUE INDEX idx_user_item_status_part_unique
      ON user_item_status_partitioned (tenant_id, user_id, item_type, item_id);

      -- Index for tenant + user scoping (most common query pattern)
      CREATE INDEX idx_user_item_status_part_tenant_user
      ON user_item_status_partitioned (tenant_id, user_id);

      -- Index for finding unread items
      CREATE INDEX idx_user_item_status_part_unread
      ON user_item_status_partitioned (tenant_id, user_id, item_type)
      WHERE has_read = false;

      -- Index for finding items not voted on
      CREATE INDEX idx_user_item_status_part_not_voted
      ON user_item_status_partitioned (tenant_id, user_id, item_type)
      WHERE has_voted = false;

      -- Index for finding items not participating in
      CREATE INDEX idx_user_item_status_part_not_participating
      ON user_item_status_partitioned (tenant_id, user_id, item_type)
      WHERE is_participating = false;
    SQL

    # Step 4: Copy data from old table to new partitioned table
    execute <<~SQL
      INSERT INTO user_item_status_partitioned (
        id, tenant_id, user_id, item_type, item_id,
        has_read, read_at, has_voted, voted_at,
        is_participating, participated_at, is_creator,
        last_viewed_at, is_mentioned
      )
      SELECT
        id, tenant_id, user_id, item_type, item_id,
        has_read, read_at, has_voted, voted_at,
        is_participating, participated_at, is_creator,
        last_viewed_at, is_mentioned
      FROM user_item_status;
    SQL

    # Step 5: Swap tables
    execute <<~SQL
      -- Drop old table
      DROP TABLE user_item_status;

      -- Rename partitioned table to original name
      ALTER TABLE user_item_status_partitioned RENAME TO user_item_status;

      -- Rename indexes to match original naming convention
      ALTER INDEX idx_user_item_status_part_unique RENAME TO idx_user_item_status_unique;
      ALTER INDEX idx_user_item_status_part_tenant_user RENAME TO idx_user_item_status_tenant_user;
      ALTER INDEX idx_user_item_status_part_unread RENAME TO idx_user_item_status_unread;
      ALTER INDEX idx_user_item_status_part_not_voted RENAME TO idx_user_item_status_not_voted;
      ALTER INDEX idx_user_item_status_part_not_participating RENAME TO idx_user_item_status_not_participating;
    SQL
  end

  def down
    # Reverse: create non-partitioned table and migrate data back
    execute <<~SQL
      CREATE TABLE user_item_status_unpartitioned (
        id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
        tenant_id uuid NOT NULL,
        user_id uuid NOT NULL,
        item_type character varying NOT NULL,
        item_id uuid NOT NULL,
        has_read boolean DEFAULT false,
        read_at timestamp(6) without time zone,
        has_voted boolean DEFAULT false,
        voted_at timestamp(6) without time zone,
        is_participating boolean DEFAULT false,
        participated_at timestamp(6) without time zone,
        is_creator boolean DEFAULT false,
        last_viewed_at timestamp(6) without time zone,
        is_mentioned boolean DEFAULT false
      );

      -- Copy data
      INSERT INTO user_item_status_unpartitioned
      SELECT * FROM user_item_status;

      -- Drop partitioned table (cascades to partitions)
      DROP TABLE user_item_status;

      -- Rename
      ALTER TABLE user_item_status_unpartitioned RENAME TO user_item_status;

      -- Recreate indexes
      CREATE UNIQUE INDEX idx_user_item_status_unique ON user_item_status (tenant_id, user_id, item_type, item_id);
      CREATE INDEX idx_user_item_status_tenant_user ON user_item_status (tenant_id, user_id);
      CREATE INDEX idx_user_item_status_unread ON user_item_status (tenant_id, user_id, item_type) WHERE has_read = false;
      CREATE INDEX idx_user_item_status_not_voted ON user_item_status (tenant_id, user_id, item_type) WHERE has_voted = false;
      CREATE INDEX idx_user_item_status_not_participating ON user_item_status (tenant_id, user_id, item_type) WHERE is_participating = false;
    SQL
  end
end
# rubocop:enable Metrics/MethodLength, Rails/SquishedSQLHeredocs
