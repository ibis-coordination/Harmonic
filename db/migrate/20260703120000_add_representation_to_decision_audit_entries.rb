class AddRepresentationToDecisionAuditEntries < ActiveRecord::Migration[7.2]
  # Schema v3: entries record both parties of a represented action. The actor
  # triple keeps meaning "the principal, on whose authority the action stands";
  # the representative columns identify who actually performed it.
  #
  # All five columns are NULL for direct (non-represented) actions and for all
  # pre-v3 entries. representative_token and representation_kind enter the v3
  # entry hash; the id/handle/salt stay out of it so they can be scrubbed, same
  # as the actor's.
  def change
    add_column :decision_audit_entries, :representative_id, :uuid
    add_column :decision_audit_entries, :representative_handle, :string
    add_column :decision_audit_entries, :representative_token, :string
    add_column :decision_audit_entries, :representative_token_salt, :string
    add_column :decision_audit_entries, :representation_kind, :string

    reversible do |dir|
      dir.up do
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
               OR NEW.representative_token IS DISTINCT FROM OLD.representative_token
               OR NEW.representation_kind IS DISTINCT FROM OLD.representation_kind
               OR NEW.option_title IS DISTINCT FROM OLD.option_title
               OR NEW.accepted IS DISTINCT FROM OLD.accepted
               OR NEW.preferred IS DISTINCT FROM OLD.preferred
               OR NEW.metadata IS DISTINCT FROM OLD.metadata
               OR NEW.previous_hash IS DISTINCT FROM OLD.previous_hash
               OR NEW.entry_hash IS DISTINCT FROM OLD.entry_hash
               OR NEW.created_at IS DISTINCT FROM OLD.created_at
            THEN
              RAISE EXCEPTION 'decision_audit_entries are immutable except for PII scrubbing (actor_id, actor_handle, actor_token_salt, representative_id, representative_handle, representative_token_salt)';
            END IF;
            RETURN NEW;
          END;
          $$;
        SQL
      end
      dir.down do
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
    end
  end
end
