# typed: strict
# frozen_string_literal: true

# Service for calculating LLM API costs based on token usage.
#
# Maintains a static pricing table for known models. Prices are per 1M tokens.
# Falls back to a default (mid-tier) price for unknown models.
#
# @example Calculate cost for a task run
#   LLMPricing.calculate_cost(
#     model: "claude-sonnet-4-20250514",
#     input_tokens: 1000,
#     output_tokens: 500
#   )
#   # => 0.0105 (USD)
#
class LLMPricing
  extend T::Sig

  # Prices per 1M tokens (USD)
  # Source: Provider pricing pages, updated manually
  # Last updated: 2026-02-11
  PRICING = T.let({
    # Claude 4 models
    "claude-sonnet-4-20250514" => { input: 3.00, output: 15.00 },
    "claude-haiku-4-20250514" => { input: 0.80, output: 4.00 },
    # Claude 3.5 models
    "claude-3-5-sonnet-20241022" => { input: 3.00, output: 15.00 },
    "claude-3-5-haiku-20241022" => { input: 0.80, output: 4.00 },
    # Claude 3 models
    "claude-3-opus-20240229" => { input: 15.00, output: 75.00 },
    "claude-3-sonnet-20240229" => { input: 3.00, output: 15.00 },
    "claude-3-haiku-20240307" => { input: 0.25, output: 1.25 },
    # OpenAI models
    "gpt-4o" => { input: 2.50, output: 10.00 },
    "gpt-4o-mini" => { input: 0.15, output: 0.60 },
    # Default fallback (assumes mid-tier model)
    "default" => { input: 3.00, output: 15.00 },
  }.freeze, T::Hash[String, { input: Float, output: Float }])

  # Calculate the estimated cost for a set of tokens.
  #
  # @param model [String] The model identifier (e.g., "claude-sonnet-4-20250514")
  # @param input_tokens [Integer] Number of input/prompt tokens
  # @param output_tokens [Integer] Number of output/completion tokens
  # @return [Float] Estimated cost in USD
  sig { params(model: String, input_tokens: Integer, output_tokens: Integer).returns(Float) }
  def self.calculate_cost(model:, input_tokens:, output_tokens:)
    pricing = PRICING[model] || PRICING.fetch("default")
    ((input_tokens / 1_000_000.0) * pricing[:input]) + ((output_tokens / 1_000_000.0) * pricing[:output])
  end

  # Check if we have pricing data for a specific model.
  #
  # @param model [String] The model identifier
  # @return [Boolean] true if the model has explicit pricing, false if using default
  sig { params(model: String).returns(T::Boolean) }
  def self.known_model?(model)
    PRICING.key?(model) && model != "default"
  end

  # List all models with explicit pricing.
  #
  # @return [Array<String>] List of model identifiers
  sig { returns(T::Array[String]) }
  def self.known_models
    PRICING.keys.reject { |k| k == "default" }
  end
end
