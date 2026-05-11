# Re-hashes every existing audit chain into the v2 schema (PII decoupled from
# hashed content; identity bound via per-(decision, actor) salted token).
#
# The rehashing logic lives inline in this migration on purpose: it's a one-off
# data migration that needs to disable the audit-immutability trigger to write
# new entry_hash / actor_token / schema_version values. Putting that capability
# in `app/services/` would expose a permanent escape hatch for the immutability
# guarantee. By keeping it here, every code path that disables the trigger lives
# under `db/migrate/`, where it's enforced by `scripts/check-audit-immutability.sh`.
#
# Idempotent: skips entries already at schema_version >= 2, so a re-run of this
# migration is a no-op.
#
# Window of opportunity: existing chains are test data — re-hashing changes
# entry_hash values, which would break externally-recorded hashes if anyone had
# them, but we're pre-launch and nobody does.
class MigrateAuditChainsToV2 < ActiveRecord::Migration[7.2]
  def up
    with_immutability_disabled do
      Decision.unscoped_for_system_job.find_each do |decision|
        rehash_decision!(decision)
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Audit chain re-hashing cannot be reversed: original entry_hash values are not retained"
  end

  private

  # Toggle the audit-immutability trigger off for the duration of the block.
  # The ALTER TABLE pair lives only here, in db/migrate/. The corresponding
  # static check (scripts/check-audit-immutability.sh) refuses any reference
  # to this trigger from app/ or lib/.
  def with_immutability_disabled
    connection.execute(
      "ALTER TABLE decision_audit_entries DISABLE TRIGGER enforce_audit_entry_immutability"
    )
    begin
      yield
    ensure
      connection.execute(
        "ALTER TABLE decision_audit_entries ENABLE TRIGGER enforce_audit_entry_immutability"
      )
    end
  end

  # Rehash a single decision's entries from v1 to v2. Caller must wrap in
  # `with_immutability_disabled`.
  def rehash_decision!(decision)
    # Snapshot up front: audit_chain_hash is set only at terminal moments
    # (executive close, beacon draw) — for ongoing decisions it's intentionally
    # NULL because DecisionAuditService.record! doesn't update it on every
    # append. Preserve that invariant: only refresh chain_hash if it was set,
    # else a later append on a non-terminal chain would mismatch the verifier.
    had_chain_hash = decision.audit_chain_hash.present?

    scope = if Tenant.current_id
              DecisionAuditEntry.where(decision_id: decision.id)
            else
              DecisionAuditEntry.tenant_scoped_only(decision.tenant_id).where(decision_id: decision.id)
            end
    entries = scope.order(:sequence_number).to_a

    return { entries_migrated: 0, entries_skipped: 0 } if entries.empty?

    migrated = 0
    skipped = 0

    # Per-decision actor_id => salt cache. First entry by an actor in this
    # decision generates a fresh salt; subsequent entries by the same actor
    # reuse it so their tokens match (vote-tally dedupe by token relies on this).
    actor_salts = {}

    # Re-hash each entry in order. Each entry's previous_hash references the
    # newly recomputed entry_hash of its predecessor (or "" for the first entry).
    previous_hash = nil

    entries.each do |entry|
      if entry.schema_version >= 2
        # Already migrated; preserve its hash and continue
        previous_hash = entry.entry_hash
        skipped += 1
        next
      end

      actor_token_salt = nil
      actor_token = nil
      if entry.actor_id.present?
        actor_token_salt = actor_salts[entry.actor_id] ||= SecureRandom.hex(32)
        actor_token = DecisionAuditService.derive_actor_token(
          decision_id: entry.decision_id,
          actor_id: entry.actor_id,
          actor_handle: entry.actor_handle.to_s,
          salt: actor_token_salt
        )
      end

      entry.schema_version = 2
      entry.actor_token = actor_token
      entry.actor_token_salt = actor_token_salt
      entry.previous_hash = previous_hash
      new_hash = DecisionAuditService.compute_hash(entry)
      entry.entry_hash = new_hash

      entry.save!(validate: false)

      previous_hash = new_hash
      migrated += 1
    end

    # Refresh the decision's chain hash to match the new last entry — but
    # only if it was already set (terminal-snapshot invariant; see top of method).
    decision.update_columns(audit_chain_hash: previous_hash) if had_chain_hash && migrated > 0 && previous_hash

    { entries_migrated: migrated, entries_skipped: skipped }
  end
end
