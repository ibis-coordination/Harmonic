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
