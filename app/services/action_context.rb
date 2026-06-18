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

    sig { returns(T::Hash[Symbol, String]) }
    def to_response_hash
      body = { error: code }
      body[:expected] = T.must(expected) unless expected.nil?
      body[:got] = T.must(got) unless got.nil?
      body
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
