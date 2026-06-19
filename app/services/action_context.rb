# typed: true

# ActionContext parses and validates the `context` block an agent must declare
# on every execute_action call. Returns Error or nil; pure (no request/DB state).
class ActionContext
  extend T::Sig

  class Error < T::Struct
    extend T::Sig
    const :code, String
    const :expected, T.nilable(String), default: nil
    const :got, T.nilable(String), default: nil

    # Short corrective pointers, surfaced as the `hint` field in every
    # rejection body. Pair with `expected`/`got` for concrete self-correction —
    # the agent shouldn't have to re-read the tool schema to know what to do.
    STATIC_HINTS = T.let({
      "context_missing" =>
        "Include a top-level `context` object with `identity`, `visibility`, and `intention`.",
      "identity_missing" =>
        "Include `identity.actor` set to your own @handle (visible on /whoami).",
      "identity_mismatch" =>
        "Set `identity.actor` to your own @handle (the one in `expected`). You can see it on /whoami.",
      "intention_missing" =>
        "Include `intention` — a short imperative phrase (think git commit subject) describing what you're doing and why.",
      "visibility_missing" =>
        "Set `visibility` to one of: public, private, shared. " \
        "Each action lists its `visibility:` in the page's YAML frontmatter — read it off there.",
      "representation_incomplete" =>
        "Declare both `representation_session_id` (top-level) and `identity.acting_as` (under identity), or neither. " \
        "To act as yourself, omit both. To act as a principal, include both.",
    }.freeze, T::Hash[String, String])

    # Visibility tier ranks. The direction of the mismatch matters: declaring
    # a smaller audience than the action actually reaches is a leak risk — the
    # agent likely picked the wrong action, not just the wrong declaration.
    VISIBILITY_RANK = T.let({
      "private" => 1, "shared" => 2, "public" => 3,
    }.freeze, T::Hash[String, Integer])

    sig { returns(T::Hash[Symbol, String]) }
    def to_response_hash
      body = { error: code }
      body[:expected] = T.must(expected) unless expected.nil?
      body[:got] = T.must(got) unless got.nil?
      hint = hint_text
      body[:hint] = hint unless hint.nil?
      body
    end

    private

    sig { returns(T.nilable(String)) }
    def hint_text
      return visibility_mismatch_hint if code == "visibility_mismatch"

      STATIC_HINTS[code]
    end

    sig { returns(T.nilable(String)) }
    def visibility_mismatch_hint
      got_value = got
      expected_value = expected
      return nil if got_value.nil? || expected_value.nil?

      got_rank = VISIBILITY_RANK[got_value]
      expected_rank = VISIBILITY_RANK[expected_value]
      return nil if got_rank.nil? || expected_rank.nil?

      pointer = "Each action lists its `visibility:` in the page's YAML frontmatter — read it off there."

      if got_rank < expected_rank
        "You declared `#{got_value}` but this action reaches a `#{expected_value}` audience — wider than you thought. " \
          "Be careful not to leak information accidentally. #{pointer}"
      else
        "You declared `#{got_value}` but this action only reaches a `#{expected_value}` audience — narrower than you thought. #{pointer}"
      end
    end
  end

  sig { params(raw: T.untyped).void }
  def initialize(raw)
    @raw = T.let(raw.is_a?(Hash) ? raw : nil, T.nilable(T::Hash[T.untyped, T.untyped]))
  end

  sig { returns(T.nilable(String)) }
  def visibility
    value = @raw&.[]("visibility")
    value.is_a?(String) ? value.presence : nil
  end

  sig { returns(T.nilable(String)) }
  def identity_actor
    identity = @raw&.[]("identity")
    return nil unless identity.is_a?(Hash)

    actor = identity["actor"]
    actor.is_a?(String) ? actor.presence : nil
  end

  sig { returns(T.nilable(String)) }
  def intention
    value = @raw&.[]("intention")
    value.is_a?(String) ? value.presence : nil
  end

  sig { returns(T.nilable(String)) }
  def representation_session_id
    value = @raw&.[]("representation_session_id")
    value.is_a?(String) ? value.presence : nil
  end

  sig { returns(T.nilable(String)) }
  def identity_acting_as
    identity = @raw&.[]("identity")
    return nil unless identity.is_a?(Hash)

    value = identity["acting_as"]
    value.is_a?(String) ? value.presence : nil
  end

  # Stage runnable from the outer MCP endpoint (needs only caller_handle).
  sig { params(caller_handle: T.nilable(String)).returns(T.nilable(Error)) }
  def validate_identity_and_intention(caller_handle:)
    return Error.new(code: "context_missing") if @raw.nil?

    actor = identity_actor
    return Error.new(code: "identity_missing") if actor.nil?

    expected_actor = "@#{caller_handle}"
    unless normalize_handle(actor) == normalize_handle(expected_actor)
      return Error.new(code: "identity_mismatch", expected: expected_actor, got: actor)
    end

    return Error.new(code: "intention_missing") if intention.nil?

    # All-or-nothing rule for representation: the agent either acts as itself
    # (both fields absent) or on behalf of someone (both fields present).
    # Exactly one is a structural mistake — fail loud so the agent doesn't
    # silently fall through to acting-as-self when it meant to represent.
    if representation_session_id.nil? != identity_acting_as.nil?
      return Error.new(code: "representation_incomplete")
    end

    nil
  end

  # Stage runnable from the inner filter chain (needs resolved audience).
  sig { params(audience: String).returns(T.nilable(Error)) }
  def validate_visibility(audience:)
    declared = visibility
    return Error.new(code: "visibility_missing") if declared.nil?
    return Error.new(code: "visibility_mismatch", expected: audience, got: declared) unless declared == audience

    nil
  end

  private

  # Handles are stored parameterized; compare the declared actor the same way
  # so "@Agent-Bob" and "agent-bob" name the same identity.
  sig { params(value: String).returns(String) }
  def normalize_handle(value)
    value.delete_prefix("@").parameterize
  end
end
