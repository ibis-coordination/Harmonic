# typed: false

require "test_helper"

# Unit tests for ActionContext — the value object that parses and validates the
# `context` block an agent must declare on every execute_action call.
#
# Validation is pure: it compares the agent's *declared* context against ground
# truth supplied by the caller (the calling agent's handle and the action's
# resolved audience tier). Mismatches return a structured error with a code and,
# where meaningful, expected/got values. `intention` is presence-only.
class ActionContextTest < ActiveSupport::TestCase
  # A well-formed self-acting context for "@agent-bob" writing to a public space.
  def valid_raw(overrides = {})
    {
      "visibility" => "public",
      "identity" => { "actor" => "@agent-bob" },
      "intention" => "vote on decision qrs789",
    }.merge(overrides)
  end

  def validate(raw, caller_handle: "agent-bob", audience: "public")
    ActionContext.new(raw).validate(caller_handle: caller_handle, audience: audience)
  end

  test "valid self-acting context passes" do
    assert_nil validate(valid_raw)
  end

  test "missing context block is context_missing" do
    err = validate(nil)
    assert_equal "context_missing", err.code
  end

  test "non-hash context block is context_missing" do
    assert_equal "context_missing", validate("nope").code
    assert_equal "context_missing", validate([]).code
  end

  test "missing identity is identity_missing" do
    assert_equal "identity_missing", validate(valid_raw("identity" => nil)).code
    assert_equal "identity_missing", validate(valid_raw("identity" => {})).code
  end

  test "identity actor not matching the caller is identity_mismatch with expected/got" do
    err = validate(valid_raw("identity" => { "actor" => "@someone-else" }))
    assert_equal "identity_mismatch", err.code
    assert_equal "@agent-bob", err.expected
    assert_equal "@someone-else", err.got
  end

  test "identity actor matches the caller regardless of case or @-prefix" do
    # Handles are stored parameterized (lowercased, slugged); a declared actor
    # that differs only in casing or the leading @ still names the same identity.
    assert_nil validate(valid_raw("identity" => { "actor" => "@Agent-Bob" }))
    assert_nil validate(valid_raw("identity" => { "actor" => "agent-bob" }))
  end

  test "non-string actor reads as identity_missing" do
    assert_equal "identity_missing", validate(valid_raw("identity" => { "actor" => 123 })).code
    assert_equal "identity_missing", validate(valid_raw("identity" => "@agent-bob")).code
  end

  test "missing or non-string intention is intention_missing" do
    assert_equal "intention_missing", validate(valid_raw("intention" => nil)).code
    assert_equal "intention_missing", validate(valid_raw("intention" => "  ")).code
    assert_equal "intention_missing", validate(valid_raw("intention" => 5)).code
  end

  test "missing visibility is visibility_missing" do
    assert_equal "visibility_missing", validate(valid_raw("visibility" => nil)).code
  end

  test "declared visibility not matching the resolved audience is visibility_mismatch with expected/got" do
    err = validate(valid_raw("visibility" => "private"), audience: "public")
    assert_equal "visibility_mismatch", err.code
    assert_equal "public", err.expected
    assert_equal "private", err.got
  end

  test "shared and private audiences validate when declared correctly" do
    assert_nil validate(valid_raw("visibility" => "shared"), audience: "shared")
    assert_nil validate(valid_raw("visibility" => "private"), audience: "private")
  end

  test "validation order: context presence before field checks" do
    # An entirely absent context reports context_missing, not a field error.
    assert_equal "context_missing", validate(nil).code
  end

  test "later-stage and unknown fields are ignored, not rejected" do
    # Forward-compat contract: a valid Stage 1 context still passes even when it
    # carries fields this stage doesn't enforce (representation/session) or
    # unknown keys. Stage 2/3 will give these meaning.
    forward = valid_raw(
      "representation_session_id" => "def456",
      "agent_session_id" => "abc123",
      "identity" => { "actor" => "@agent-bob", "on_behalf_of" => "@principal-alice" },
      "future_field" => "whatever"
    )
    assert_nil validate(forward)
  end
end
