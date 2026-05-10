# typed: false

require "test_helper"
require Rails.root.join("db/migrate/20260510000002_migrate_audit_chains_to_v2.rb")

# Tests for the v1→v2 audit chain migration.
#
# The rehashing logic lives inline in the migration on purpose (see comments
# in the migration file) — keeping it out of `app/services/` means the only
# code path that disables the audit-immutability trigger is in `db/migrate/`,
# enforced by `scripts/check-audit-immutability.sh`.
#
# These tests reach into the migration's private helpers via `.send` so they
# can drive a single decision rather than iterating every Decision in the DB.
class AuditChainV2MigrationTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @option = create_option(decision: @decision, created_by: @user, title: "Option A")
    @migration = MigrateAuditChainsToV2.new
  end

  # Drive the migration's per-decision logic. Mirrors what `up` does but for
  # one decision, so tests don't depend on global Decision state.
  def migrate_decision!(decision)
    @migration.send(:with_immutability_disabled) do
      @migration.send(:rehash_decision!, decision)
    end
  end

  # Helper: create a v1 entry directly, bypassing record! (which writes v2).
  # Mirrors the v1 hash function from DecisionAuditService for fidelity.
  def create_v1_entry!(decision:, sequence_number:, action:, actor_id:, actor_handle:, previous_hash: nil, option_title: nil, accepted: nil, preferred: nil, metadata: nil)
    created_at = Time.current.change(usec: 0)
    sorted_metadata = metadata ? JSON.generate(metadata.sort.to_h) : ""
    normalized_title = option_title.nil? ? "" : option_title.unicode_normalize(:nfc)
    hash_input = [
      "v1",
      previous_hash || "",
      sequence_number.to_s,
      action,
      actor_id || "",
      actor_handle || "",
      normalized_title,
      accepted.nil? ? "" : accepted.to_s,
      preferred.nil? ? "" : preferred.to_s,
      sorted_metadata,
      created_at.iso8601,
    ].join("|")
    entry_hash = Digest::SHA256.hexdigest(hash_input)

    DecisionAuditEntry.create!(
      tenant: decision.tenant, collective: decision.collective, decision: decision,
      sequence_number: sequence_number, schema_version: 1, action: action,
      actor_id: actor_id, actor_handle: actor_handle,
      option_title: option_title, accepted: accepted, preferred: preferred,
      metadata: metadata&.transform_keys(&:to_s),
      previous_hash: previous_hash, entry_hash: entry_hash, created_at: created_at,
    )
  end

  test "migrates a single v1 entry to v2 with token and salt populated" do
    e1 = create_v1_entry!(
      decision: @decision, sequence_number: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: "Option A",
    )

    migrate_decision!(@decision)

    e1.reload
    assert_equal 2, e1.schema_version
    assert e1.actor_token.present?
    assert e1.actor_token_salt.present?
    expected_token = Digest::SHA256.hexdigest("#{e1.decision_id}|#{e1.actor_id}|#{e1.actor_handle}|#{e1.actor_token_salt}")
    assert_equal expected_token, e1.actor_token
  end

  test "migrated chain passes verifier and binding checks" do
    e1 = create_v1_entry!(
      decision: @decision, sequence_number: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: "Option A",
    )
    create_v1_entry!(
      decision: @decision, sequence_number: 2, action: "decision_closed",
      actor_id: @user.id, actor_handle: @user.handle, previous_hash: e1.entry_hash,
    )

    migrate_decision!(@decision)

    chain_result = DecisionAuditVerifier.verify_chain(@decision)
    assert chain_result[:valid], chain_result[:errors].inspect

    DecisionAuditEntry.where(decision_id: @decision.id).find_each do |e|
      assert_equal :verified, DecisionAuditVerifier.verify_actor_binding(e),
                   "entry seq=#{e.sequence_number} action=#{e.action} did not verify"
    end
  end

  test "all entries by the same actor in a decision share the same actor_token (vote-tally dedupe relies on this)" do
    e1 = create_v1_entry!(
      decision: @decision, sequence_number: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: "Option A",
    )
    create_v1_entry!(
      decision: @decision, sequence_number: 2, action: "decision_closed",
      actor_id: @user.id, actor_handle: @user.handle, previous_hash: e1.entry_hash,
    )

    migrate_decision!(@decision)

    tokens = DecisionAuditEntry.where(decision_id: @decision.id, actor_id: @user.id).pluck(:actor_token).uniq
    assert_equal 1, tokens.size, "Same actor should have one stable token across entries"
  end

  test "system entries (no actor) get NULL token and salt after migration" do
    e1 = create_v1_entry!(
      decision: @decision, sequence_number: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: "Option A",
    )
    # System entry: no actor. Compute v1 hash inline so we don't need to mutate after create.
    created_at = Time.current.change(usec: 0)
    metadata = { "round" => 12345, "randomness" => "abc" }
    sorted_metadata = JSON.generate(metadata.sort.to_h)
    hash_input = ["v1", e1.entry_hash, "2", "beacon_drawn", "", "", "", "", "", sorted_metadata, created_at.iso8601].join("|")
    e2 = DecisionAuditEntry.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      sequence_number: 2, schema_version: 1, action: "beacon_drawn",
      actor_id: nil, actor_handle: nil, metadata: metadata,
      previous_hash: e1.entry_hash,
      entry_hash: Digest::SHA256.hexdigest(hash_input),
      created_at: created_at,
    )

    migrate_decision!(@decision)

    e2.reload
    assert_nil e2.actor_token
    assert_nil e2.actor_token_salt
    assert_equal 2, e2.schema_version
  end

  test "Decision#audit_chain_hash is updated to the new last entry's hash when it was already set" do
    e1 = create_v1_entry!(
      decision: @decision, sequence_number: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: "Option A",
    )
    e2 = create_v1_entry!(
      decision: @decision, sequence_number: 2, action: "decision_closed",
      actor_id: @user.id, actor_handle: @user.handle, previous_hash: e1.entry_hash,
    )
    @decision.update!(audit_chain_hash: e2.entry_hash)

    migrate_decision!(@decision)

    @decision.reload
    last_entry = DecisionAuditEntry.where(decision_id: @decision.id).order(:sequence_number).last
    assert_equal last_entry.entry_hash, @decision.audit_chain_hash
  end

  test "Decision#audit_chain_hash stays NULL after migration when it was NULL before (non-terminal decision)" do
    # audit_chain_hash is a snapshot taken at terminal moments (executive
    # close, beacon draw). For ongoing decisions it's intentionally NULL —
    # the migrator must not break this invariant by setting it on every chain.
    create_v1_entry!(
      decision: @decision, sequence_number: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: "Option A",
    )
    @decision.update_columns(audit_chain_hash: nil)
    assert_nil @decision.reload.audit_chain_hash, "precondition: non-terminal decision has NULL chain_hash"

    migrate_decision!(@decision)

    @decision.reload
    assert_nil @decision.audit_chain_hash,
               "Migrator must not set chain_hash for decisions that didn't have it set; " \
               "doing so breaks verify_chain when a new entry is later appended " \
               "(record! does not update chain_hash on each save by design)."
  end

  test "verify_chain passes after migration when a new entry is appended to a non-terminal decision" do
    # User-reported bug: open a pre-launch decision that's been migrated, cast
    # a new vote, then visit the verify page → "Final chain hash mismatch".
    # Reproduces because the migrator was setting chain_hash on a non-terminal
    # decision; the next record! call appended an entry without updating
    # chain_hash, leaving it pointing at the previous-last entry.
    create_v1_entry!(
      decision: @decision, sequence_number: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: "Option A",
    )
    @decision.update_columns(audit_chain_hash: nil)
    migrate_decision!(@decision)

    # Append a new entry post-migration (any record! call — the bug doesn't
    # depend on which action it is).
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )

    result = DecisionAuditVerifier.verify_chain(@decision)
    assert result[:valid], "Chain must verify after appending an entry post-migration: #{result[:errors].inspect}"
  end

  test "migration is idempotent — running twice produces the same end state" do
    e1 = create_v1_entry!(
      decision: @decision, sequence_number: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle, option_title: "Option A",
    )
    create_v1_entry!(
      decision: @decision, sequence_number: 2, action: "decision_closed",
      actor_id: @user.id, actor_handle: @user.handle, previous_hash: e1.entry_hash,
    )

    migrate_decision!(@decision)
    snapshot = DecisionAuditEntry.where(decision_id: @decision.id).order(:sequence_number).pluck(:entry_hash, :actor_token, :actor_token_salt)

    result = @migration.send(:with_immutability_disabled) do
      @migration.send(:rehash_decision!, @decision)
    end
    assert_equal 0, result[:entries_migrated], "Second run should migrate nothing"

    after = DecisionAuditEntry.where(decision_id: @decision.id).order(:sequence_number).pluck(:entry_hash, :actor_token, :actor_token_salt)
    assert_equal snapshot, after
  end

  test "leaves already-v2 entries alone" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    snapshot = DecisionAuditEntry.where(decision_id: @decision.id).order(:sequence_number).pluck(:entry_hash, :schema_version)

    result = @migration.send(:with_immutability_disabled) do
      @migration.send(:rehash_decision!, @decision)
    end
    assert_equal 0, result[:entries_migrated]

    after = DecisionAuditEntry.where(decision_id: @decision.id).order(:sequence_number).pluck(:entry_hash, :schema_version)
    assert_equal snapshot, after
  end
end
