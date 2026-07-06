# typed: false

require "test_helper"

class DecisionAuditServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @option = create_option(decision: @decision, created_by: @user, title: "Option A")
  end

  # --- record_creation! ---

  test "record_creation! creates a decision_created entry with initial values in metadata" do
    entry = DecisionAuditService.record_creation!(decision: @decision, actor: @user)
    assert_equal "decision_created", entry.action
    assert_equal 1, entry.sequence_number
    assert_equal @user.id, entry.actor_id
    assert_nil entry.previous_hash
    assert entry.entry_hash.present?
    assert_equal @decision.question, entry.metadata["question"]
    assert_equal @decision.description, entry.metadata["description"]
    assert_equal @decision.subtype, entry.metadata["subtype"]
    assert_equal @decision.deadline.iso8601, entry.metadata["deadline"]
    assert_equal @decision.options_open.to_s, entry.metadata["options_open"]
  end

  test "record_creation! includes decision_maker_id for executive decisions" do
    exec_decision = Decision.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      question: "Exec?", description: "test", deadline: 1.week.from_now,
      options_open: true, subtype: "executive", decision_maker: @user,
    )
    entry = DecisionAuditService.record_creation!(decision: exec_decision, actor: @user)
    assert_equal @user.id, entry.metadata["decision_maker_id"]
  end

  test "record_creation! omits decision_maker_id for vote decisions" do
    entry = DecisionAuditService.record_creation!(decision: @decision, actor: @user)
    assert_not entry.metadata.key?("decision_maker_id")
  end

  # --- record_update! ---

  test "record_update! creates a decision_updated entry with changed fields in metadata" do
    entry = DecisionAuditService.record_update!(
      decision: @decision, actor: @user,
      changes: { "deadline" => [1.week.from_now.iso8601, 2.weeks.from_now.iso8601] },
    )
    assert_equal "decision_updated", entry.action
    assert_equal @user.id, entry.actor_id
    assert entry.metadata.key?("deadline")
  end

  # --- record_option! ---

  test "record_option! creates an option_added entry" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_equal "option_added", entry.action
    assert_equal 1, entry.sequence_number
    assert_equal @user.id, entry.actor_id
    assert_equal @user.handle, entry.actor_handle
    assert_equal "Option A", entry.option_title
    assert_nil entry.accepted
    assert_nil entry.preferred
    assert_nil entry.previous_hash
    assert_equal DecisionAuditEntry::CURRENT_SCHEMA_VERSION, entry.schema_version
    assert entry.entry_hash.present?
  end

  test "record_option_update! creates an option_updated entry with old and new title" do
    entry = DecisionAuditService.record_option_update!(
      decision: @decision, option: @option, actor: @user,
      old_title: "Option A", new_title: "Option A (revised)",
    )
    assert_equal "option_updated", entry.action
    assert_equal "Option A (revised)", entry.option_title
    assert_equal({ "old_title" => "Option A", "new_title" => "Option A (revised)" }, entry.metadata)
  end

  test "record_option! creates an option_removed entry" do
    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_removed",
    )
    assert_equal "option_removed", entry.action
    assert_equal 2, entry.sequence_number
    assert entry.previous_hash.present?
  end

  # --- record_vote! ---

  test "record_vote! creates a vote_cast entry for new vote" do
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )

    entry = DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user)
    assert_equal "vote_cast", entry.action
    assert_equal "Option A", entry.option_title
    assert_equal 1, entry.accepted
    assert_equal 0, entry.preferred
  end

  test "record_vote! creates a vote_updated entry for existing vote" do
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )
    # Record first vote
    DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user)

    # Update and record again
    vote.update!(accepted: 0, preferred: 1)
    entry = DecisionAuditService.record_vote!(decision: @decision, vote: vote, actor: @user, is_update: true)
    assert_equal "vote_updated", entry.action
    assert_equal 0, entry.accepted
    assert_equal 1, entry.preferred
    assert_equal 2, entry.sequence_number
  end

  # --- record_close! ---

  test "record_close! creates a decision_closed entry" do
    entry = DecisionAuditService.record_close!(decision: @decision, actor: @user)
    assert_equal "decision_closed", entry.action
    assert_nil entry.option_title
    assert_nil entry.accepted
    assert_nil entry.preferred
    assert_equal @user.id, entry.actor_id
  end

  # --- record_beacon! ---

  test "record_beacon! creates a beacon_drawn entry with metadata" do
    entry = DecisionAuditService.record_beacon!(
      decision: @decision, round: 12345, randomness: "abc123hex",
    )
    assert_equal "beacon_drawn", entry.action
    assert_nil entry.actor_id
    assert_nil entry.actor_handle
    assert_nil entry.option_title
    assert_equal({ "randomness" => "abc123hex", "round" => 12345 }, entry.metadata)
  end

  # --- Chain linking ---

  test "chain links correctly across multiple entries" do
    e1 = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_nil e1.previous_hash
    assert e1.entry_hash.present?

    e2 = DecisionAuditService.record_close!(decision: @decision, actor: @user)
    assert_equal e1.entry_hash, e2.previous_hash
    assert e2.entry_hash.present?
    assert_not_equal e1.entry_hash, e2.entry_hash

    e3 = DecisionAuditService.record_beacon!(
      decision: @decision, round: 99, randomness: "deadbeef",
    )
    assert_equal e2.entry_hash, e3.previous_hash
    assert_equal 3, e3.sequence_number
  end

  # --- current-version entries: token + salt + schema_version ---

  test "new entries are written with schema_version = 3" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_equal 3, entry.schema_version
  end

  test "entries with an actor have actor_token and actor_token_salt populated" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert entry.actor_token.present?, "actor_token should be set"
    assert entry.actor_token_salt.present?, "actor_token_salt should be set"
  end

  test "actor_token_salt is 64 hex characters (256 bits)" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_match(/\A[0-9a-f]{64}\z/, entry.actor_token_salt)
  end

  test "actor_token is SHA256(decision_id || actor_id || actor_handle || salt)" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    expected = Digest::SHA256.hexdigest("#{entry.decision_id}|#{entry.actor_id}|#{entry.actor_handle}|#{entry.actor_token_salt}")
    assert_equal expected, entry.actor_token
  end

  test "system entries (no actor) have NULL actor_token and NULL actor_token_salt" do
    entry = DecisionAuditService.record_beacon!(decision: @decision, round: 99, randomness: "deadbeef")
    assert_nil entry.actor_token
    assert_nil entry.actor_token_salt
  end

  test "subsequent entries by the same actor in the same decision reuse the salt and produce the same actor_token" do
    # Vote-tally dedupe replays votes by actor_token. If a user casts a vote and
    # then updates it, both entries must share an actor_token so they collapse to
    # one voter. record! must NOT generate a fresh salt for each append.
    e1 = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    e2 = DecisionAuditService.record_close!(decision: @decision, actor: @user)

    assert_equal e1.actor_token_salt, e2.actor_token_salt,
                 "record! must reuse the salt across entries by the same actor in the same decision"
    assert_equal e1.actor_token, e2.actor_token,
                 "stable actor_token across same-actor entries is required for vote-tally dedupe"
  end

  test "actor_token and stored actor_handle stay stable when the participant's handle changes between entries" do
    # If a participant renames between actions in the same decision, the
    # actor_token must NOT change — otherwise vote-tally dedupe groups the
    # same voter's vote_cast and vote_updated under different tokens and
    # double-counts them. The token derivation (and the stored actor_handle)
    # anchors to the participant's first handle in this decision, not the
    # handle in effect at each individual moment of action.
    e1 = DecisionAuditService.record_vote!(
      decision: @decision,
      vote: Vote.new(option: @option, accepted: 1, preferred: 0),
      actor: @user,
    )
    original_handle = @user.handle

    # Simulate the participant renaming themselves between actions.
    @user.handle = "renamed-#{SecureRandom.hex(4)}"
    e2 = DecisionAuditService.record_vote!(
      decision: @decision,
      vote: Vote.new(option: @option, accepted: 0, preferred: 0),
      actor: @user,
      is_update: true,
    )

    assert_equal e1.actor_token, e2.actor_token,
                 "actor_token must stay stable across a handle change in the same decision"
    assert_equal original_handle, e2.actor_handle,
                 "stored actor_handle anchors to the first entry's handle in this decision"
  end

  test "record! does NOT update Decision#audit_chain_hash (terminal-snapshot invariant)" do
    # audit_chain_hash is a snapshot taken at terminal moments only
    # (executive close in DecisionActionService, beacon draw). For ongoing
    # decisions it stays NULL, and the migrator preserves that. If record!
    # ever started updating chain_hash on every append, the verifier's final
    # hash check would either become trivial (always-matches) or break for
    # any chain that wasn't single-shot.
    assert_nil @decision.reload.audit_chain_hash, "precondition: chain_hash starts NULL"

    DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_nil @decision.reload.audit_chain_hash,
               "record! must not touch audit_chain_hash; only executive close and beacon draw set it"

    DecisionAuditService.record_vote!(
      decision: @decision,
      vote: Vote.new(option: @option, accepted: 1, preferred: 0),
      actor: @user,
    )
    assert_nil @decision.reload.audit_chain_hash,
               "record! must not touch audit_chain_hash even on subsequent appends"
  end

  test "different actors in the same decision get different salts" do
    other_user = create_user(name: "Other Voter")
    @tenant.add_user!(other_user)

    e1 = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    other_option = create_option(decision: @decision, created_by: other_user, title: "Option B")
    e2 = DecisionAuditService.record_option!(
      decision: @decision, option: other_option, actor: other_user, action: "option_added",
    )

    refute_equal e1.actor_token_salt, e2.actor_token_salt,
                 "Different actors must get different salts so their tokens are distinct"
    refute_equal e1.actor_token, e2.actor_token
  end

  # --- v3 hash content ---

  test "v3 entry_hash includes actor_token but not actor_id or actor_handle directly" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    expected_input = [
      "v3",
      "",  # no previous_hash for first entry
      "1",
      "option_added",
      entry.actor_token,
      "",  # representative_token is nil (direct action)
      "",  # representation_kind is nil (direct action)
      "Option A",
      "",  # accepted is nil
      "",  # preferred is nil
      "",  # metadata is nil
      entry.created_at.iso8601,
    ].join("|")
    expected_hash = Digest::SHA256.hexdigest(expected_input)
    assert_equal expected_hash, entry.entry_hash
  end

  test "entry_hash is unchanged if actor_id or actor_handle change (chain integrity decoupled from PII)" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    original_hash = entry.entry_hash

    # Simulate a PII scrub: NULL out actor_id, replace handle with placeholder
    entry.update_columns(actor_id: nil, actor_handle: "[deleted account]")

    recomputed = DecisionAuditService.compute_hash(entry)
    assert_equal original_hash, recomputed,
                 "entry_hash must not change when actor_id or actor_handle are scrubbed"
  end

  test "entry_hash is unchanged if actor_token_salt changes (salt is not in the hash)" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    original_hash = entry.entry_hash

    entry.update_columns(actor_token_salt: SecureRandom.hex(32))
    recomputed = DecisionAuditService.compute_hash(entry)
    assert_equal original_hash, recomputed,
                 "entry_hash must not include actor_token_salt"
  end

  test "entry_hash changes if actor_token changes (token IS in the hash)" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    original_hash = entry.entry_hash

    # The DB trigger forbids mutating actor_token. Compute a hash on an in-memory
    # entry with a different token to confirm the token affects entry_hash.
    entry.actor_token = SecureRandom.hex(32)
    recomputed = DecisionAuditService.compute_hash(entry)
    refute_equal original_hash, recomputed,
                 "entry_hash must change if actor_token is altered"
  end

  # === Representation (schema v3) ===
  #
  # Actions performed through a representation session must record both
  # parties in the tamper-evident chain: actor (the principal — unchanged
  # semantics) and representative (the user who actually performed it).

  def create_trustee_member(name: "Trustee")
    trustee = create_user(name: name)
    @tenant.add_user!(trustee)
    @collective.add_user!(trustee)
    trustee
  end

  def create_user_representation_session(principal:, trustee:)
    grant = create_trustee_authorization(
      tenant: @tenant, granting_user: principal, trustee_user: trustee,
      permissions: { "vote" => true }, accepted: true,
    )
    create_trustee_authorization_representation_session(tenant: @tenant, trustee_grant: grant)
  end

  test "record_option! with a user representation session records both identities" do
    trustee = create_trustee_member
    session = create_user_representation_session(principal: @user, trustee: trustee)

    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
      representation_session: session,
    )

    assert_equal 3, entry.schema_version
    assert_equal @user.id, entry.actor_id
    assert_equal trustee.id, entry.representative_id
    assert_equal trustee.handle, entry.representative_handle
    assert entry.representative_token.present?
    assert entry.representative_token_salt.present?
    assert_equal "user", entry.representation_kind
    assert_equal entry.entry_hash, DecisionAuditService.compute_hash(entry),
                 "represented entry must verify against the v3 hash formula"
  end

  test "record_vote! with a user representation session records the representative" do
    trustee = create_trustee_member
    session = create_user_representation_session(principal: @user, trustee: trustee)
    participant = DecisionParticipantManager.new(decision: @decision, user: @user).find_or_create_participant
    vote = Vote.create!(
      tenant: @tenant, collective: @collective, decision: @decision,
      option: @option, decision_participant: participant,
      accepted: 1, preferred: 0,
    )

    entry = DecisionAuditService.record_vote!(
      decision: @decision, vote: vote, actor: @user, representation_session: session,
    )
    assert_equal @user.id, entry.actor_id
    assert_equal trustee.id, entry.representative_id
    assert_equal "user", entry.representation_kind
  end

  test "collective representation records kind collective and the representative" do
    identity = @collective.identity_user
    assert identity.present?, "test collective must have an identity user"
    session = create_representation_session(
      tenant: @tenant, collective: @collective, representative: @user,
    )

    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: identity, action: "option_added",
      representation_session: session,
    )
    assert_equal identity.id, entry.actor_id
    assert_equal @user.id, entry.representative_id
    assert_equal "collective", entry.representation_kind
  end

  test "direct actions leave all representative fields nil" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_nil entry.representative_id
    assert_nil entry.representative_handle
    assert_nil entry.representative_token
    assert_nil entry.representative_token_salt
    assert_nil entry.representation_kind
  end

  test "representative_token is SHA256(decision_id || representative_id || representative_handle || salt)" do
    trustee = create_trustee_member
    session = create_user_representation_session(principal: @user, trustee: trustee)
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
      representation_session: session,
    )

    expected = Digest::SHA256.hexdigest(
      "#{entry.decision_id}|#{entry.representative_id}|#{entry.representative_handle}|#{entry.representative_token_salt}",
    )
    assert_equal expected, entry.representative_token
  end

  test "representative token and salt anchor to the representative's first represented entry" do
    trustee = create_trustee_member
    session = create_user_representation_session(principal: @user, trustee: trustee)
    first = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
      representation_session: session,
    )

    trustee.handle = "renamed-#{SecureRandom.hex(4)}"
    second = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_removed",
      representation_session: session,
    )

    assert_equal first.representative_token_salt, second.representative_token_salt,
                 "salt must be reused per (decision, representative)"
    assert_equal first.representative_token, second.representative_token,
                 "token must stay stable across a representative rename"
    assert_equal first.representative_handle, second.representative_handle,
                 "stored handle is the anchor handle, not the current one"
  end

  test "representative anchoring is independent of entries where the same user was the actor" do
    trustee = create_trustee_member
    direct = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: trustee, action: "option_added",
    )
    session = create_user_representation_session(principal: @user, trustee: trustee)
    represented = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_removed",
      representation_session: session,
    )

    refute_equal direct.actor_token_salt, represented.representative_token_salt,
                 "representative salt must not reuse the user's actor salt"
  end

  test "representation is ignored when the session's effective_user is not the actor" do
    trustee = create_trustee_member
    other = create_trustee_member(name: "Bystander")
    # Session represents @user, but the recorded action belongs to other.
    session = create_user_representation_session(principal: @user, trustee: trustee)

    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: other, action: "option_added",
      representation_session: session,
    )
    assert_equal other.id, entry.actor_id
    assert_nil entry.representative_id
    assert_nil entry.representation_kind
  end

  test "v3 hash input includes representative token and kind after the actor token" do
    trustee = create_trustee_member
    session = create_user_representation_session(principal: @user, trustee: trustee)
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
      representation_session: session,
    )

    input = DecisionAuditService.hash_input(entry)
    assert input.start_with?("v3|")
    assert_includes input, "|#{entry.actor_token}|#{entry.representative_token}|user|"
  end

  test "entry_hash is unchanged when representative PII is scrubbed (id, handle, salt are not in the hash)" do
    trustee = create_trustee_member
    session = create_user_representation_session(principal: @user, trustee: trustee)
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
      representation_session: session,
    )
    original_hash = entry.entry_hash

    entry.update_columns(representative_id: nil, representative_handle: "[deleted account]", representative_token_salt: nil)
    assert_equal original_hash, DecisionAuditService.compute_hash(entry),
                 "entry_hash must not change when representative PII is scrubbed"
  end

  # --- v2 backward compatibility ---

  test "v2 hash function still works for legacy entries" do
    v2_entry = DecisionAuditEntry.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      sequence_number: 1, schema_version: 2, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle,
      actor_token: "abc123token",
      option_title: "Option A",
      created_at: Time.zone.parse("2026-01-01T12:00:00Z"),
    )

    expected_input = [
      "v2",
      "",
      "1",
      "option_added",
      "abc123token",
      "Option A",
      "",
      "",
      "",
      v2_entry.created_at.iso8601,
    ].join("|")
    expected_hash = Digest::SHA256.hexdigest(expected_input)

    assert_equal expected_hash, DecisionAuditService.compute_hash(v2_entry)
  end

  # --- v1 backward compatibility ---

  test "v1 hash function still works for legacy entries" do
    # Forge a v1 entry manually to confirm the legacy hashing function is intact
    v1_entry = DecisionAuditEntry.new(
      tenant: @tenant, collective: @collective, decision: @decision,
      sequence_number: 1, schema_version: 1, action: "option_added",
      actor_id: @user.id, actor_handle: @user.handle,
      option_title: "Option A",
      created_at: Time.zone.parse("2026-01-01T12:00:00Z"),
    )

    expected_input = [
      "v1",
      "",
      "1",
      "option_added",
      @user.id,
      @user.handle,
      "Option A",
      "",
      "",
      "",
      v1_entry.created_at.iso8601,
    ].join("|")
    expected_hash = Digest::SHA256.hexdigest(expected_input)

    assert_equal expected_hash, DecisionAuditService.compute_hash(v1_entry)
  end

  # --- Skips for pre-launch decisions ---

  test "returns nil for decisions created before launch date" do
    @decision.update_columns(created_at: Time.utc(2020, 1, 1))
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_nil entry
  end
end
