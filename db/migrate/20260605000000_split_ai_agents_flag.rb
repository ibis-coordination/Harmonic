# Splits the single `ai_agents` feature flag into two independent flags:
# `internal_ai_agents` (Task Runner) and `external_ai_agents` (API-token
# agents). Preserves every tenant's current capability set by copying the
# existing `ai_agents` value (or 'false' default) into both new keys, then
# deletes the old key.
#
# Run-once (not idempotent): the third statement removes the source `ai_agents`
# key, so a hypothetical second run would COALESCE-default both new flags back
# to 'false'. Rails' schema_migrations tracking is the correctness story.
#
# The `collectives` table cleanup is defensive — `ai_agents` is
# `collective_level: false` and shouldn't have been settable per-collective,
# but if any historical write put it there, remove it.
class SplitAiAgentsFlag < ActiveRecord::Migration[7.2]
  def up
    execute <<-SQL
      UPDATE tenants
      SET settings = jsonb_set(
        settings,
        '{feature_flags,internal_ai_agents}',
        COALESCE(settings->'feature_flags'->'ai_agents', 'false'::jsonb),
        true
      )
    SQL

    execute <<-SQL
      UPDATE tenants
      SET settings = jsonb_set(
        settings,
        '{feature_flags,external_ai_agents}',
        COALESCE(settings->'feature_flags'->'ai_agents', 'false'::jsonb),
        true
      )
    SQL

    execute <<-SQL
      UPDATE tenants
      SET settings = settings #- '{feature_flags,ai_agents}'
      WHERE settings->'feature_flags' ? 'ai_agents'
    SQL

    execute <<-SQL
      UPDATE collectives
      SET settings = settings #- '{feature_flags,ai_agents}'
      WHERE settings->'feature_flags' ? 'ai_agents'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
