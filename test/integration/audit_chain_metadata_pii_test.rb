# typed: false

require "test_helper"

# Pins the metadata shape produced by every DecisionAuditService.record_*
# method, so a future change that routes actor PII into metadata fails the
# test rather than silently undermining the scrubbing guarantee.
#
# Rule (see DecisionAuditService docstring): metadata may contain decision
# CONTENT (question, description, option titles, deadlines, system values
# like beacon round/randomness) but must not contain actor IDENTITY (display
# name, email, handle, personal pronouns, etc.). Scrubbing only NULLs the
# actor_id/actor_handle/actor_token_salt columns; metadata stays as-is.
class AuditChainMetadataPiiTest < ActiveSupport::TestCase
  ALLOWED_KEYS = %w[
    question description subtype deadline options_open decision_maker_id
    voter_eligibility proposer_eligibility
    old_title new_title
    round randomness
  ].freeze

  ACTOR_PII_KEYS = %w[
    actor_id actor_handle actor_name actor_email actor_display_name
    user_id user_handle user_name user_email display_name handle email name
    representative_id representative_handle representative_name representative_email
    trustee_id trustee_handle
  ].freeze

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    @option = create_option(decision: @decision, created_by: @user, title: "Option A")
  end

  def assert_metadata_pii_safe(entry, label)
    return if entry.metadata.blank?
    keys = entry.metadata.keys.map(&:to_s)
    leaked = keys & ACTOR_PII_KEYS
    assert leaked.empty?,
           "#{label} put actor-identity keys into metadata: #{leaked.inspect}. " \
           "Move actor identity to typed columns (actor_id, actor_handle) — " \
           "see DecisionAuditService docstring."
    unexpected = keys - ALLOWED_KEYS
    assert unexpected.empty?,
           "#{label} added unexpected metadata keys: #{unexpected.inspect}. " \
           "If this is a new decision-content field, add it to ALLOWED_KEYS. " \
           "If it's an actor-identity field, move it to a typed column."

    nested = nested_keys(entry.metadata) & ACTOR_PII_KEYS
    assert nested.empty?,
           "#{label} put actor-identity keys inside a metadata value: #{nested.inspect}. " \
           "A permitted top-level key does not license identifiers nested under it."
    assert_no_human_identifiers(entry, label)
  end

  # Top-level keys are not the whole story: a permitted key can carry a nested
  # structure, and the eligibility rules are JSON strings holding clause hashes.
  # Walk everything, parsing strings that turn out to be JSON.
  def nested_keys(value)
    case value
    when Hash then value.keys.map(&:to_s) + value.values.flat_map { |v| nested_keys(v) }
    when Array then value.flat_map { |v| nested_keys(v) }
    when String
      parsed = begin
        JSON.parse(value)
      rescue JSON::ParserError, TypeError
        nil
      end
      parsed ? nested_keys(parsed) : []
    else []
    end
  end

  # User ids are permitted (see the DecisionAuditService docstring); handles,
  # names and emails are not, at any depth. Checking the rendered blob catches
  # them regardless of what key they arrive under.
  def assert_no_human_identifiers(entry, label)
    blob = JSON.generate(entry.metadata)
    identifiers = [@user.handle, @user.name, @user.email].compact.reject(&:blank?)
    # Without this the guard passes vacuously the moment the fixture stops
    # producing a handle, and nothing would say so.
    assert identifiers.any?, "#{label}: no identifiers to search for."
    found = identifiers.select { |value| blob.include?(value) }
    assert found.empty?,
           "#{label} put human-meaningful identifiers into metadata: #{found.inspect}. " \
           "Ids are opaque and may stay; handles, names and emails identify a " \
           "person outside this database and cannot be taken back."
  end

  test "record_creation! metadata contains only decision-content keys" do
    entry = DecisionAuditService.record_creation!(decision: @decision, actor: @user)
    assert_metadata_pii_safe(entry, "record_creation!")
  end

  test "an electorate is recorded as ids, never as handles" do
    @decision.update!(voter_eligibility: {
      "any_of" => [{ "type" => "users", "user_ids" => [@user.id] }],
    })

    entry = DecisionAuditService.record_creation!(decision: @decision, actor: @user)

    assert_metadata_pii_safe(entry, "record_creation! with an electorate")
    # Deliberately present: the id is what makes the electorate contestable,
    # and it carries no meaning outside this database.
    assert_includes entry.metadata["voter_eligibility"].to_s, @user.id
  end

  test "DecisionActionService.update_decision! produces PII-safe metadata" do
    # The realistic caller. update_decision! filters changes through
    # `decision.changes.except("updated_at")` before passing to record_update!.
    # This pins both the service method and its production caller against
    # routing actor-identity fields through the changes hash.
    @decision.description = "Updated description"
    result = DecisionActionService.update_decision!(decision: @decision, actor: @user)
    assert_metadata_pii_safe(result[:audit_entry], "DecisionActionService.update_decision!")
  end

  test "record_option_update! metadata contains only old_title/new_title" do
    entry = DecisionAuditService.record_option_update!(
      decision: @decision, option: @option, actor: @user,
      old_title: "Option A", new_title: "Option A (revised)",
    )
    assert_metadata_pii_safe(entry, "record_option_update!")
  end

  test "record_vote! has no metadata" do
    entry = DecisionAuditService.record_vote!(
      decision: @decision,
      vote: Vote.new(option: @option, accepted: 1, preferred: 0),
      actor: @user,
    )
    assert_nil entry.metadata, "record_vote! should write nil metadata"
  end

  test "record_option! has no metadata" do
    entry = DecisionAuditService.record_option!(
      decision: @decision, option: @option, actor: @user, action: "option_added",
    )
    assert_nil entry.metadata, "record_option! should write nil metadata"
  end

  test "record_close! has no metadata" do
    entry = DecisionAuditService.record_close!(decision: @decision, actor: @user)
    assert_nil entry.metadata, "record_close! should write nil metadata"
  end

  test "record_beacon! metadata contains only system values (round, randomness)" do
    entry = DecisionAuditService.record_beacon!(
      decision: @decision, round: 12345, randomness: "deadbeef",
    )
    assert_metadata_pii_safe(entry, "record_beacon!")
    assert_equal %w[randomness round], entry.metadata.keys.map(&:to_s).sort
  end
end
