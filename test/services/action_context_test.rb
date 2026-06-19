# typed: false

require "test_helper"

class ActionContextTest < ActiveSupport::TestCase
  def valid_raw(overrides = {})
    {
      "visibility" => "public",
      "identity" => { "actor" => "@agent-bob" },
      "intention" => "vote on decision qrs789",
    }.merge(overrides)
  end

  # Mirrors the production two-stage flow: outer gate then inner gate.
  def validate(raw, caller_handle: "agent-bob", audience: "public")
    ctx = ActionContext.new(raw)
    ctx.validate_identity_and_intention(caller_handle: caller_handle) ||
      ctx.validate_visibility(audience: audience)
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

  test "validate_identity_and_intention covers context/identity/intention checks but not visibility" do
    ctx = ActionContext.new(nil)
    assert_equal "context_missing", ctx.validate_identity_and_intention(caller_handle: "agent-bob").code

    ctx = ActionContext.new(valid_raw("identity" => nil))
    assert_equal "identity_missing", ctx.validate_identity_and_intention(caller_handle: "agent-bob").code

    ctx = ActionContext.new(valid_raw("identity" => { "actor" => "@someone-else" }))
    err = ctx.validate_identity_and_intention(caller_handle: "agent-bob")
    assert_equal "identity_mismatch", err.code
    assert_equal "@agent-bob", err.expected
    assert_equal "@someone-else", err.got

    ctx = ActionContext.new(valid_raw("intention" => nil))
    assert_equal "intention_missing", ctx.validate_identity_and_intention(caller_handle: "agent-bob").code

    # Visibility is the next stage's concern, not this one's.
    ctx = ActionContext.new(valid_raw("visibility" => nil))
    assert_nil ctx.validate_identity_and_intention(caller_handle: "agent-bob")
  end

  test "validate_visibility covers only visibility checks" do
    ctx = ActionContext.new(valid_raw("visibility" => nil))
    assert_equal "visibility_missing", ctx.validate_visibility(audience: "public").code

    ctx = ActionContext.new(valid_raw("visibility" => "private"))
    err = ctx.validate_visibility(audience: "public")
    assert_equal "visibility_mismatch", err.code
    assert_equal "public", err.expected
    assert_equal "private", err.got

    ctx = ActionContext.new(valid_raw)
    assert_nil ctx.validate_visibility(audience: "public")
  end

  test "Error#to_response_hash includes a static hint for non-mismatch codes" do
    ActionContext::Error::STATIC_HINTS.each do |code, expected_hint|
      err = ActionContext::Error.new(code: code)
      body = err.to_response_hash
      assert_equal code, body[:error]
      assert_equal expected_hint, body[:hint], "missing hint for #{code}"
    end
  end

  test "visibility_mismatch hint warns about leak risk when declared tier is narrower than actual" do
    # Declared a narrower audience than reality → potential leak. The hint
    # surfaces the leak risk so the agent doesn't mechanically flip `visibility`
    # and proceed past a model error.
    err = ActionContext::Error.new(code: "visibility_mismatch", expected: "public", got: "private")
    hint = err.to_response_hash[:hint]
    assert_match(/wider than you thought/, hint)
    assert_match(/leak/i, hint)
  end

  test "visibility_mismatch hint names the misalignment when declared tier is wider than actual" do
    # Declared a wider audience than reality → lower-stakes; the hint just
    # names the misalignment and lets the agent decide what to do.
    err = ActionContext::Error.new(code: "visibility_mismatch", expected: "private", got: "public")
    hint = err.to_response_hash[:hint]
    assert_match(/narrower than you thought/, hint)
  end

  test "visibility_mismatch hint distinguishes all six (got, expected) pairs by direction" do
    leak_risk_pairs = [["private", "shared"], ["private", "public"], ["shared", "public"]]
    over_cautious_pairs = [["shared", "private"], ["public", "private"], ["public", "shared"]]

    leak_risk_pairs.each do |got, expected|
      hint = ActionContext::Error.new(code: "visibility_mismatch", expected: expected, got: got).to_response_hash[:hint]
      assert_match(/wider/, hint, "expected wider-than-declared phrasing for got=#{got} expected=#{expected}")
    end

    over_cautious_pairs.each do |got, expected|
      hint = ActionContext::Error.new(code: "visibility_mismatch", expected: expected, got: got).to_response_hash[:hint]
      assert_match(/narrower/, hint, "expected narrower-than-declared phrasing for got=#{got} expected=#{expected}")
    end
  end

  test "visibility_mismatch hint is omitted when got or expected is missing or unknown" do
    assert_not ActionContext::Error.new(code: "visibility_mismatch").to_response_hash.key?(:hint)
    assert_not ActionContext::Error.new(code: "visibility_mismatch", got: "private").to_response_hash.key?(:hint)
    assert_not ActionContext::Error.new(code: "visibility_mismatch", got: "bogus", expected: "public").to_response_hash.key?(:hint)
  end

  test "Error#to_response_hash omits hint when no hint is registered for the code" do
    err = ActionContext::Error.new(code: "unregistered_code")
    assert_not err.to_response_hash.key?(:hint)
  end

  test "unknown and not-yet-meaningful fields are ignored, not rejected" do
    # Forward-compat contract: a valid context still passes even when it carries
    # fields with no current meaning. Today that's `agent_session_id` (the next
    # stage) and arbitrary unknown keys.
    forward = valid_raw(
      "agent_session_id" => "abc123",
      "future_field" => "whatever"
    )
    assert_nil validate(forward)
  end

  # --- Representation (acting on behalf of a principal/collective) ---

  test "declaring both representation_session_id and identity.acting_as passes the structural check" do
    # All-or-nothing structural check: both fields present satisfies the rule.
    # (The semantic check — that the session exists, is owned by the agent, and
    # that acting_as matches the session's effective_user — is performed in
    # the controller layer, not here in the pure value object.)
    raw = valid_raw(
      "representation_session_id" => "def456",
      "identity" => { "actor" => "@agent-bob", "acting_as" => "@principal-alice" }
    )
    assert_nil validate(raw)
  end

  test "declaring neither representation field is acting-as-self and passes" do
    # No representation declared = Stage 1 behavior, unchanged.
    assert_nil validate(valid_raw)
  end

  test "declaring representation_session_id without acting_as returns representation_incomplete" do
    raw = valid_raw("representation_session_id" => "def456")
    err = validate(raw)
    assert_equal "representation_incomplete", err.code
  end

  test "declaring acting_as without representation_session_id returns representation_incomplete" do
    raw = valid_raw("identity" => { "actor" => "@agent-bob", "acting_as" => "@principal-alice" })
    err = validate(raw)
    assert_equal "representation_incomplete", err.code
  end

  test "blank-string representation_session_id reads as absent (no field)" do
    # Treat empty/whitespace identically to "field omitted" so a sloppy LLM
    # emitting an empty string doesn't trigger representation_incomplete.
    raw = valid_raw(
      "representation_session_id" => "  ",
      "identity" => { "actor" => "@agent-bob" }
    )
    assert_nil validate(raw)
  end

  test "blank-string acting_as reads as absent (no field)" do
    raw = valid_raw("identity" => { "actor" => "@agent-bob", "acting_as" => "  " })
    assert_nil validate(raw)
  end

  test "representation_session_id accessor returns the declared value" do
    ctx = ActionContext.new(valid_raw("representation_session_id" => "def456"))
    assert_equal "def456", ctx.representation_session_id
  end

  test "identity_acting_as accessor returns the declared value" do
    ctx = ActionContext.new(valid_raw("identity" => { "actor" => "@agent-bob", "acting_as" => "@principal-alice" }))
    assert_equal "@principal-alice", ctx.identity_acting_as
  end

  test "representation_incomplete carries a corrective hint" do
    err = ActionContext::Error.new(code: "representation_incomplete")
    body = err.to_response_hash
    assert_equal "representation_incomplete", body[:error]
    assert body[:hint].present?
    assert_match(/representation_session_id/, body[:hint])
    assert_match(/acting_as/, body[:hint])
  end
end
