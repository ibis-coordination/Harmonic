class CreateDecisionAuditEntries < ActiveRecord::Migration[7.2]
  def up
    create_table :decision_audit_entries, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :collective, type: :uuid, null: false, foreign_key: true
      t.references :decision, type: :uuid, null: false, foreign_key: true
      t.integer :sequence_number, null: false
      t.integer :schema_version, null: false, default: 1
      t.string :action, null: false
      t.uuid :actor_id
      t.string :actor_handle
      t.string :option_title
      t.integer :accepted
      t.integer :preferred
      t.jsonb :metadata
      t.string :previous_hash
      t.string :entry_hash, null: false

      t.datetime :created_at, null: false
    end

    add_index :decision_audit_entries, [:decision_id, :sequence_number], unique: true, name: "idx_audit_entries_decision_sequence"
    add_index :decision_audit_entries, :decision_id, name: "idx_audit_entries_decision"

    add_column :decisions, :audit_chain_hash, :string

    # Layer 2: Immutable audit entries — prevent UPDATE (not DELETE, which is needed for data deletion)
    execute <<~SQL
      CREATE FUNCTION prevent_audit_entry_mutation() RETURNS TRIGGER AS $$
      BEGIN
        RAISE EXCEPTION 'decision_audit_entries are immutable — updates are not allowed';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER enforce_audit_entry_immutability
        BEFORE UPDATE ON decision_audit_entries
        FOR EACH ROW EXECUTE FUNCTION prevent_audit_entry_mutation();
    SQL

    # Layer 3: Prevent vote creation/modification after decision close (not DELETE, which is needed for data deletion)
    execute <<~SQL
      CREATE FUNCTION prevent_vote_mutation_after_close() RETURNS TRIGGER AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM decisions
          WHERE id = NEW.decision_id
          AND deadline < NOW()
        ) THEN
          RAISE EXCEPTION 'Votes cannot be created or modified after the decision is closed';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER enforce_vote_immutability_after_close
        BEFORE INSERT OR UPDATE ON votes
        FOR EACH ROW EXECUTE FUNCTION prevent_vote_mutation_after_close();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS enforce_vote_immutability_after_close ON votes;
      DROP FUNCTION IF EXISTS prevent_vote_mutation_after_close();
      DROP TRIGGER IF EXISTS enforce_audit_entry_immutability ON decision_audit_entries;
      DROP FUNCTION IF EXISTS prevent_audit_entry_mutation();
    SQL

    remove_column :decisions, :audit_chain_hash
    drop_table :decision_audit_entries
  end
end
