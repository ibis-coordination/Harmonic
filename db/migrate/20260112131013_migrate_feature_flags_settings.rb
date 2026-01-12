class MigrateFeatureFlagsSettings < ActiveRecord::Migration[7.0]
  def up
    # Migrate tenant settings to feature_flags hash
    execute <<-SQL
      UPDATE tenants
      SET settings = jsonb_set(
        jsonb_set(
          settings,
          '{feature_flags}',
          COALESCE(settings->'feature_flags', '{}'::jsonb),
          true
        ),
        '{feature_flags,api}',
        COALESCE(settings->'api_enabled', 'false'::jsonb),
        true
      )
    SQL

    execute <<-SQL
      UPDATE tenants
      SET settings = jsonb_set(
        settings,
        '{feature_flags,file_attachments}',
        COALESCE(settings->'allow_file_uploads', 'false'::jsonb),
        true
      )
    SQL

    # Migrate studio settings to feature_flags hash
    # Note: Studios already have feature_flags.api, so we only need file_attachments
    execute <<-SQL
      UPDATE studios
      SET settings = jsonb_set(
        jsonb_set(
          settings,
          '{feature_flags}',
          COALESCE(settings->'feature_flags', '{}'::jsonb),
          true
        ),
        '{feature_flags,file_attachments}',
        COALESCE(settings->'allow_file_uploads', 'true'::jsonb),
        true
      )
    SQL
  end

  def down
    # This migration is safe to leave as-is on rollback
    # The old settings keys are still present and the code has legacy fallback
  end
end
