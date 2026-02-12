# typed: false

require "test_helper"

class LLMPricingTest < ActiveSupport::TestCase
  test "calculate_cost for known claude model" do
    cost = LLMPricing.calculate_cost(
      model: "claude-sonnet-4-20250514",
      input_tokens: 1_000_000,
      output_tokens: 100_000
    )
    # 1M input * $3/1M + 100k output * $15/1M = $3 + $1.50 = $4.50
    assert_in_delta 4.50, cost, 0.0001
  end

  test "calculate_cost for known gpt model" do
    cost = LLMPricing.calculate_cost(
      model: "gpt-4o",
      input_tokens: 1_000_000,
      output_tokens: 1_000_000
    )
    # 1M input * $2.50/1M + 1M output * $10/1M = $2.50 + $10 = $12.50
    assert_in_delta 12.50, cost, 0.0001
  end

  test "calculate_cost uses default for unknown model" do
    cost = LLMPricing.calculate_cost(
      model: "unknown-model-xyz",
      input_tokens: 1_000_000,
      output_tokens: 1_000_000
    )
    # Default: 1M input * $3/1M + 1M output * $15/1M = $3 + $15 = $18
    assert_in_delta 18.0, cost, 0.0001
  end

  test "calculate_cost with small token counts" do
    cost = LLMPricing.calculate_cost(
      model: "claude-sonnet-4-20250514",
      input_tokens: 1000,
      output_tokens: 500
    )
    # 1000 input * $3/1M + 500 output * $15/1M = $0.003 + $0.0075 = $0.0105
    assert_in_delta 0.0105, cost, 0.0001
  end

  test "calculate_cost with zero tokens returns zero" do
    cost = LLMPricing.calculate_cost(
      model: "claude-sonnet-4-20250514",
      input_tokens: 0,
      output_tokens: 0
    )
    assert_equal 0.0, cost
  end

  test "known_model? returns true for known models" do
    assert LLMPricing.known_model?("claude-sonnet-4-20250514")
    assert LLMPricing.known_model?("gpt-4o")
    assert LLMPricing.known_model?("claude-3-opus-20240229")
  end

  test "known_model? returns false for unknown models" do
    assert_not LLMPricing.known_model?("unknown-model")
    assert_not LLMPricing.known_model?("default")
  end

  test "known_models returns list of known models without default" do
    models = LLMPricing.known_models
    assert models.include?("claude-sonnet-4-20250514")
    assert models.include?("gpt-4o")
    assert_not models.include?("default")
  end
end
