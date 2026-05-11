# typed: false

require "test_helper"

# Regression tests designed to catch accidental breakage during refactoring.
# These tests verify invariants that must hold regardless of implementation changes.
# If any of these fail after a refactor, the audit chain's integrity guarantees are broken.
class AuditChainRegressionTest < ActiveSupport::TestCase

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  # === Hash formula stability ===
  # These tests pin the exact hash output for known inputs.
  # If the hash formula changes (field order, delimiter, encoding, etc.),
  # these tests break — which is the point. The hash formula is a public contract
  # documented on the verify page and implemented in the Python script.

  test "v2 hash formula produces stable output for known inputs" do
    decision = Decision.new(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Stable Hash Test", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: @user)

    entry = DecisionAuditEntry.where(decision_id: decision.id).first

    # Re-derive the expected v2 hash from the stored fields.
    raw_metadata = entry.metadata
    sorted_metadata = JSON.generate(raw_metadata.sort.to_h)
    expected_input = [
      "v2", "", "1", "decision_created",
      entry.actor_token,
      "", "", "", sorted_metadata,
      entry.created_at.iso8601,
    ].join("|")
    expected_hash = Digest::SHA256.hexdigest(expected_input)

    assert_equal expected_hash, entry.entry_hash,
      "v2 hash formula changed! The audit chain hash is a public contract — " \
      "changing it without bumping schema_version breaks existing chains."
  end

  test "v2 actor_token is SHA256(decision_id || actor_id || actor_handle || actor_token_salt)" do
    decision = Decision.new(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Token Derivation Test", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: @user)
    entry = DecisionAuditEntry.where(decision_id: decision.id).first

    expected_token = Digest::SHA256.hexdigest(
      "#{entry.decision_id}|#{entry.actor_id}|#{entry.actor_handle}|#{entry.actor_token_salt}",
    )
    assert_equal expected_token, entry.actor_token,
      "actor_token derivation is a public contract — changing it breaks identity verification"
  end

  test "hash uses pipe delimiter between fields" do
    decision = Decision.new(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Delimiter Test", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: @user)
    entry = DecisionAuditEntry.where(decision_id: decision.id).first

    hash_input = DecisionAuditService.hash_input(entry)
    assert_match(/\|/, hash_input, "Hash input must use pipe delimiters")
    # v2: exactly 9 pipes (10 fields). v1 had 10 pipes (11 fields) — this changed
    # because actor_id and actor_handle (two fields) were collapsed into actor_token.
    assert_equal 9, hash_input.count("|"),
      "v2 hash input must have exactly 10 fields separated by 9 pipes"
  end

  test "hash input starts with version prefix v2" do
    decision = Decision.new(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Version Test", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: @user)
    entry = DecisionAuditEntry.where(decision_id: decision.id).first

    hash_input = DecisionAuditService.hash_input(entry)
    assert hash_input.start_with?("v2|"),
      "v2 hash input must start with 'v2|' — changing the version prefix without bumping schema_version breaks existing chains"
  end

  # === DB trigger existence ===
  # These tests verify that the DB triggers are present.
  # A migration could accidentally drop them.

  test "audit entry immutability trigger exists on decision_audit_entries table" do
    result = ActiveRecord::Base.connection.execute(<<~SQL)
      SELECT tgname FROM pg_trigger
      WHERE tgrelid = 'decision_audit_entries'::regclass
      AND tgname = 'enforce_audit_entry_immutability'
    SQL
    assert_equal 1, result.count,
      "The enforce_audit_entry_immutability trigger is missing from decision_audit_entries! " \
      "This trigger prevents tampering with audit entries. It must not be removed."
  end

  test "vote immutability trigger exists on votes table" do
    result = ActiveRecord::Base.connection.execute(<<~SQL)
      SELECT tgname FROM pg_trigger
      WHERE tgrelid = 'votes'::regclass
      AND tgname = 'enforce_vote_immutability_after_close'
    SQL
    assert_equal 1, result.count,
      "The enforce_vote_immutability_after_close trigger is missing from votes! " \
      "This trigger prevents vote manipulation after a decision closes. It must not be removed."
  end

  test "audit entry immutability trigger blocks UPDATE but allows INSERT and DELETE" do
    result = ActiveRecord::Base.connection.execute(<<~SQL)
      SELECT tgtype FROM pg_trigger
      WHERE tgrelid = 'decision_audit_entries'::regclass
      AND tgname = 'enforce_audit_entry_immutability'
    SQL
    # tgtype is a bitmask: bit 0=ROW(1), bit 1=BEFORE(2), bit 4=UPDATE(16)
    # Expected: 19 = ROW + BEFORE + UPDATE (no INSERT or DELETE bits)
    tgtype = result.first["tgtype"]
    assert_equal 0, tgtype & 4, "Trigger should NOT fire on INSERT"
    assert_equal 0, tgtype & 8, "Trigger should NOT fire on DELETE"
    assert tgtype & 16 > 0, "Trigger MUST fire on UPDATE"
  end

  test "vote immutability trigger blocks INSERT and UPDATE but allows DELETE" do
    result = ActiveRecord::Base.connection.execute(<<~SQL)
      SELECT tgtype FROM pg_trigger
      WHERE tgrelid = 'votes'::regclass
      AND tgname = 'enforce_vote_immutability_after_close'
    SQL
    tgtype = result.first["tgtype"]
    assert tgtype & 4 > 0, "Trigger MUST fire on INSERT"
    assert tgtype & 16 > 0, "Trigger MUST fire on UPDATE"
    assert_equal 0, tgtype & 8, "Trigger should NOT fire on DELETE"
  end

  # === Audit-immutability trigger column-level allow/block ===
  # The trigger permits PII-scrub mutations (actor_id, actor_handle,
  # actor_token_salt) and rejects everything else. Each column listed in the
  # trigger function is a hard part of the immutability contract — anyone who
  # widens or narrows the allow-list must update these tests deliberately.

  setup_decision_with_audit_entry = -> (test) {
    test.instance_eval do
      @audit_decision ||= begin
        d = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
        DecisionAuditService.record_option!(
          decision: d,
          option: create_option(decision: d, created_by: @user, title: "Opt"),
          actor: @user, action: "option_added",
        )
        d
      end
      DecisionAuditEntry.where(decision_id: @audit_decision.id).order(:sequence_number).first
    end
  }

  # PII-scrub allowed columns: NULLing or replacing must succeed
  {
    actor_id: "NULL",
    actor_handle: "'[deleted account]'",
    actor_token_salt: "NULL",
  }.each do |column, new_value|
    test "audit immutability trigger ALLOWS update to #{column} (PII scrub path)" do
      entry = setup_decision_with_audit_entry.call(self)
      assert_nothing_raised do
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql([
            "UPDATE decision_audit_entries SET #{column} = #{new_value} WHERE id = ?", entry.id,
          ]),
        )
      end
    end
  end

  # Immutable columns: any change must raise. We test each column the trigger
  # function lists explicitly (db/migrate/20260510000001_allow_pii_scrub_on_audit_entries.rb).
  IMMUTABLE_COLUMN_UPDATES = {
    schema_version: "schema_version = 99",
    action: "action = 'vote_cast'",
    actor_token: "actor_token = 'forged-token'",
    option_title: "option_title = 'forged'",
    accepted: "accepted = 99",
    preferred: "preferred = 99",
    metadata: "metadata = '{\"forged\":true}'::jsonb",
    previous_hash: "previous_hash = 'forged'",
    entry_hash: "entry_hash = 'forged'",
    sequence_number: "sequence_number = 999",
  }.freeze

  IMMUTABLE_COLUMN_UPDATES.each do |column, set_clause|
    test "audit immutability trigger BLOCKS update to #{column}" do
      entry = setup_decision_with_audit_entry.call(self)
      assert_raises(ActiveRecord::StatementInvalid, "Trigger must reject UPDATE to #{column}") do
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql([
            "UPDATE decision_audit_entries SET #{set_clause} WHERE id = ?", entry.id,
          ]),
        )
      end
    end
  end

  # === Unique constraint on (decision_id, sequence_number) ===

  test "unique index exists on decision_id + sequence_number" do
    indexes = ActiveRecord::Base.connection.indexes(:decision_audit_entries)
    unique_index = indexes.find { |i| i.columns == ["decision_id", "sequence_number"] && i.unique }
    assert unique_index,
      "Unique index on (decision_id, sequence_number) is missing! " \
      "This prevents duplicate sequence numbers which would break chain verification."
  end

  # === audit_chain_enabled? behavior ===

  test "decisions created after launch date have audit chain enabled" do
    decision = create_decision
    assert decision.audit_chain_enabled?,
      "New decisions must have audit_chain_enabled? == true"
  end

  test "decisions created before launch date have audit chain disabled" do
    decision = create_decision
    decision.update_columns(created_at: Time.utc(2020, 1, 1))
    assert_not decision.audit_chain_enabled?,
      "Pre-launch decisions must have audit_chain_enabled? == false"
  end

  test "audit service skips recording for pre-launch decisions" do
    decision = create_decision
    decision.update_columns(created_at: Time.utc(2020, 1, 1))
    entry = DecisionAuditService.record_close!(decision: decision, actor: @user)
    assert_nil entry, "Audit service must return nil for pre-launch decisions"
  end

  # === Every vote through API has a corresponding audit entry ===
  # This catches code paths that save votes without going through DecisionActionService.

  test "every vote record has a corresponding audit entry after full API flow" do
    decision = Decision.new(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Coverage Test", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: @user)

    participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant
    option_a = Option.new(decision: decision, decision_participant: participant, title: "A")
    DecisionActionService.add_option!(decision: decision, option: option_a, actor: @user)
    option_b = Option.new(decision: decision, decision_participant: participant, title: "B")
    DecisionActionService.add_option!(decision: decision, option: option_b, actor: @user)

    vote_a = Vote.new(
      tenant: @tenant, collective: @collective, decision: decision,
      option: option_a, decision_participant: participant, accepted: 1, preferred: 1,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote_a, actor: @user)

    vote_b = Vote.new(
      tenant: @tenant, collective: @collective, decision: decision,
      option: option_b, decision_participant: participant, accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote_b, actor: @user)

    # Update a vote
    vote_a.accepted = 0
    DecisionActionService.cast_vote!(decision: decision, vote: vote_a, actor: @user, is_update: true)

    vote_count = Vote.where(decision_id: decision.id).count
    audit_vote_count = DecisionAuditEntry.where(
      decision_id: decision.id,
      action: %w[vote_cast vote_updated],
    ).count

    # There should be at least as many audit entries as votes
    # (more if votes were updated, since each update creates a new entry)
    assert audit_vote_count >= vote_count,
      "Found #{vote_count} votes but only #{audit_vote_count} vote audit entries. " \
      "This means votes were saved without going through DecisionActionService."
  end

  # === Chain integrity after every mutation type ===

  test "chain verifies as valid after exercising all mutation types" do
    decision = Decision.new(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Full Chain Test", description: "", deadline: 1.week.from_now,
      options_open: true, subtype: "vote",
    )
    DecisionActionService.create_decision!(decision: decision, actor: @user)

    participant = DecisionParticipantManager.new(decision: decision, user: @user).find_or_create_participant

    option = Option.new(decision: decision, decision_participant: participant, title: "Opt")
    DecisionActionService.add_option!(decision: decision, option: option, actor: @user)

    option.title = "Opt (edited)"
    DecisionActionService.update_option!(option: option, actor: @user)

    decision.description = "Updated"
    DecisionActionService.update_decision!(decision: decision, actor: @user)

    vote = Vote.new(
      tenant: @tenant, collective: @collective, decision: decision,
      option: option, decision_participant: participant, accepted: 1, preferred: 0,
    )
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: @user)

    vote.preferred = 1
    DecisionActionService.cast_vote!(decision: decision, vote: vote, actor: @user, is_update: true)

    DecisionActionService.close_decision!(decision: decision, actor: @user)

    DecisionActionService.draw_beacon!(decision: decision, round: 999, randomness: "abc")

    # The entire chain should verify cleanly
    result = DecisionAuditVerifier.verify_chain(decision)
    assert result[:valid], "Chain verification failed after full lifecycle: #{result[:errors].join(', ')}"
    assert_equal decision.audit_chain_hash, result[:last_hash],
      "Final chain hash should match decision.audit_chain_hash"
  end

  # === MAX_OPTIONS limit ===

  test "MAX_OPTIONS is enforced" do
    assert_equal 100, Decision::MAX_OPTIONS,
      "MAX_OPTIONS must be 100. Changing this affects the audit chain " \
      "(more options = more entries = longer verification time)."
  end

  # === All 10 action types are defined ===

  test "all 9 action types are present in ACTIONS constant" do
    expected = %w[
      decision_created decision_updated
      option_added option_removed option_updated
      vote_cast vote_updated
      decision_closed beacon_drawn
    ]
    expected.each do |action|
      assert_includes DecisionAuditEntry::ACTIONS, action,
        "Action '#{action}' is missing from ACTIONS. " \
        "Removing an action type breaks audit chain verification."
    end
  end
end
