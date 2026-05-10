class AllowPiiScrubOnAuditEntries < ActiveRecord::Migration[7.2]
  # Audit entries are immutable by design, BUT PII scrubbing on account closure
  # legitimately needs to NULL out actor_id and actor_token_salt and replace
  # actor_handle. The new immutability check rejects mutations to any other
  # column, so the chain integrity guarantees and the entry hash itself remain
  # protected — only the three identity-binding fields can change.
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_audit_entry_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.id IS DISTINCT FROM OLD.id
           OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
           OR NEW.collective_id IS DISTINCT FROM OLD.collective_id
           OR NEW.decision_id IS DISTINCT FROM OLD.decision_id
           OR NEW.sequence_number IS DISTINCT FROM OLD.sequence_number
           OR NEW.schema_version IS DISTINCT FROM OLD.schema_version
           OR NEW.action IS DISTINCT FROM OLD.action
           OR NEW.actor_token IS DISTINCT FROM OLD.actor_token
           OR NEW.option_title IS DISTINCT FROM OLD.option_title
           OR NEW.accepted IS DISTINCT FROM OLD.accepted
           OR NEW.preferred IS DISTINCT FROM OLD.preferred
           OR NEW.metadata IS DISTINCT FROM OLD.metadata
           OR NEW.previous_hash IS DISTINCT FROM OLD.previous_hash
           OR NEW.entry_hash IS DISTINCT FROM OLD.entry_hash
           OR NEW.created_at IS DISTINCT FROM OLD.created_at
        THEN
          RAISE EXCEPTION 'decision_audit_entries are immutable except for PII scrubbing (actor_id, actor_handle, actor_token_salt)';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
  end

  def down
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_audit_entry_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'decision_audit_entries are immutable — updates are not allowed';
      END;
      $$;
    SQL
  end
end
