# typed: true
# frozen_string_literal: true

# Resolves an agent's configured model to the `provider/model` name the Stripe
# AI Gateway expects. Model names match the gateway's naming scheme 1-to-1 —
# config/litellm_config.yaml uses the same names — so no translation happens
# here: blank/"default" resolves to DEFAULT_MODEL, provider-prefixed names pass
# through (the gateway rejects unsupported models at request time), and names
# the gateway cannot proxy (local Ollama models, Arcee Trinity) raise so
# dispatch fails fast with a clear error instead of a 400 at request time.
class StripeGatewayModelMapper
  extend T::Sig

  class UnmappedModelError < StandardError; end

  DEFAULT_MODEL = "anthropic/claude-sonnet-4.6"

  sig { params(model: T.nilable(String)).returns(String) }
  def self.map(model)
    return DEFAULT_MODEL if model.blank? || model == "default"
    return model if model.include?("/")

    raise UnmappedModelError, "Model \"#{model}\" is not available through the Stripe gateway. " \
                              "Gateway models use provider/model names, e.g. #{DEFAULT_MODEL}."
  end
end
