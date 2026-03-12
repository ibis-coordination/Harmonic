# typed: strict
# frozen_string_literal: true

# Maps LiteLLM model names to Stripe AI Gateway format (provider/model).
# Stripe's gateway uses the format "provider/model" for routing.
class StripeModelMapper
  extend T::Sig

  class UnsupportedModelError < StandardError; end

  # LiteLLM name => Stripe gateway name
  MODEL_MAP = T.let({
    "default" => "anthropic/claude-sonnet-4",
    "claude-sonnet-4-20250514" => "anthropic/claude-sonnet-4",
    "claude-haiku-4" => "anthropic/claude-haiku-4-5",
    "claude-haiku-4-20250514" => "anthropic/claude-haiku-4-5",
    "gpt-4o" => "openai/gpt-4o",
  }.freeze, T::Hash[String, String])

  sig { params(model: String).returns(String) }
  def self.to_stripe(model)
    mapped = MODEL_MAP[model]
    raise UnsupportedModelError, "Model '#{model}' is not supported on Stripe AI Gateway" unless mapped

    mapped
  end

  sig { params(model: String).returns(T::Boolean) }
  def self.supported?(model)
    MODEL_MAP.key?(model)
  end
end
