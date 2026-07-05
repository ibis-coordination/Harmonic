# typed: true
# frozen_string_literal: true

# Translates LiteLLM model aliases (what agents store in agent_configuration)
# into the `provider/model` format the Stripe AI Gateway expects. Names the
# gateway cannot proxy (local Ollama models, Arcee Trinity) raise so dispatch
# fails fast with a clear error instead of a 400 at request time.
class StripeGatewayModelMapper
  extend T::Sig

  class UnmappedModelError < StandardError; end

  DEFAULT_MODEL = "anthropic/claude-sonnet-4.6"

  # LiteLLM alias => Stripe gateway provider/model. Gateway names use dotted
  # versions (claude-sonnet-4.6), unlike the dashed Anthropic API ids in
  # config/litellm_config.yaml — see the supported-models list in Stripe's
  # token-billing integration guide.
  MODEL_MAP = T.let({
    "claude-sonnet-4" => "anthropic/claude-sonnet-4.6",
    "claude-haiku-4" => "anthropic/claude-haiku-4.5",
    "claude-opus-4" => "anthropic/claude-opus-4.7",
    "gpt-4o" => "openai/gpt-4o",
  }.freeze, T::Hash[String, String])

  sig { params(model: T.nilable(String)).returns(String) }
  def self.map(model)
    return DEFAULT_MODEL if model.blank? || model == "default"

    # Already provider-prefixed — trust the operator and pass it through;
    # the gateway rejects unsupported models at request time.
    return model if model.include?("/")

    MODEL_MAP.fetch(model) do
      raise UnmappedModelError, "Model \"#{model}\" is not available through the Stripe gateway. " \
                                "Available models: #{MODEL_MAP.keys.join(", ")}."
    end
  end
end
