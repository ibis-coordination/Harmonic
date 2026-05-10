class BumpAuditSchemaVersionDefaultTo2 < ActiveRecord::Migration[7.2]
  # CURRENT_SCHEMA_VERSION on DecisionAuditEntry is 2 since the PII-decoupling
  # work. The DB default still pointed at 1, which would silently produce a v1
  # row if any future code path ever omitted schema_version on insert.
  # Existing rows are not touched — they were rehashed by the v1→v2 migrator
  # and already carry the right value.
  def change
    change_column_default :decision_audit_entries, :schema_version, from: 1, to: 2
  end
end
