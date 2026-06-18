# typed: true

# ActionContext parses and validates the `context` block an agent must declare
# on every execute_action call.
#
# Validation is pure and compares the agent's *declared* context against ground
# truth supplied by the caller:
#
#   - identity.actor    must resolve to the calling agent's own handle
#   - intention         must be present (content is never inspected — recorded only)
#   - visibility        must match the action's resolved audience tier
#
# A mismatch returns an Error with a machine-readable `code` and, where
# meaningful, `expected`/`got` values so the agent can self-correct. Returns nil
# when the context is valid.
#
# This object is deliberately free of Rails request/DB state: the concern that
# wires it into the action pipeline supplies `caller_handle` and `audience`.
class ActionContext
  extend T::Sig

  class Error < T::Struct
    const :code, String
    const :expected, T.nilable(String), default: nil
    const :got, T.nilable(String), default: nil
  end

  sig { params(raw: T.untyped).void }
  def initialize(raw)
    @raw = T.let(raw.is_a?(Hash) ? raw : nil, T.nilable(T::Hash[T.untyped, T.untyped]))
  end

  # The declared tier, only if it's a non-blank string.
  sig { returns(T.nilable(String)) }
  def visibility
    value = @raw&.[]("visibility")
    value.is_a?(String) ? value.presence : nil
  end

  # The declared actor handle, only if `identity` is a hash whose `actor` is a
  # non-blank string. Non-string/missing actors read as absent.
  sig { returns(T.nilable(String)) }
  def identity_actor
    identity = @raw&.[]("identity")
    return nil unless identity.is_a?(Hash)

    actor = identity["actor"]
    actor.is_a?(String) ? actor.presence : nil
  end

  # The declared intention, only if it's a non-blank string. Content is never
  # validated beyond presence.
  sig { returns(T.nilable(String)) }
  def intention
    value = @raw&.[]("intention")
    value.is_a?(String) ? value.presence : nil
  end

  sig { params(caller_handle: T.nilable(String), audience: String).returns(T.nilable(Error)) }
  def validate(caller_handle:, audience:)
    return Error.new(code: "context_missing") if @raw.nil?

    actor = identity_actor
    return Error.new(code: "identity_missing") if actor.nil?

    expected_actor = "@#{caller_handle}"
    unless normalize_handle(actor) == normalize_handle(expected_actor)
      return Error.new(code: "identity_mismatch", expected: expected_actor, got: actor)
    end

    return Error.new(code: "intention_missing") if intention.nil?

    declared = visibility
    return Error.new(code: "visibility_missing") if declared.nil?

    return Error.new(code: "visibility_mismatch", expected: audience, got: declared) unless declared == audience

    nil
  end

  private

  # Handles are stored normalized via `parameterize` (lowercased, slugged), so
  # compare the declared actor the same way: "@Agent-Bob" and "agent-bob" name
  # the same identity. `parameterize` already drops a leading "@", and the
  # explicit strip keeps intent obvious.
  sig { params(value: String).returns(String) }
  def normalize_handle(value)
    value.delete_prefix("@").parameterize
  end
end
