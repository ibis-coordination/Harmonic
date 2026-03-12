require "test_helper"

class StripeModelMapperTest < ActiveSupport::TestCase
  # === Mapping tests ===

  test "maps default to anthropic/claude-sonnet-4" do
    assert_equal "anthropic/claude-sonnet-4", StripeModelMapper.to_stripe("default")
  end

  test "maps claude-sonnet-4-20250514 to anthropic/claude-sonnet-4" do
    assert_equal "anthropic/claude-sonnet-4", StripeModelMapper.to_stripe("claude-sonnet-4-20250514")
  end

  test "maps claude-haiku-4 to anthropic/claude-haiku-4-5" do
    assert_equal "anthropic/claude-haiku-4-5", StripeModelMapper.to_stripe("claude-haiku-4")
  end

  test "maps claude-haiku-4-20250514 to anthropic/claude-haiku-4-5" do
    assert_equal "anthropic/claude-haiku-4-5", StripeModelMapper.to_stripe("claude-haiku-4-20250514")
  end

  test "maps gpt-4o to openai/gpt-4o" do
    assert_equal "openai/gpt-4o", StripeModelMapper.to_stripe("gpt-4o")
  end

  # === Unsupported model tests ===

  test "raises UnsupportedModelError for deepseek-r1" do
    error = assert_raises(StripeModelMapper::UnsupportedModelError) do
      StripeModelMapper.to_stripe("deepseek-r1")
    end
    assert_match(/deepseek-r1/, error.message)
  end

  test "raises UnsupportedModelError for gemma3" do
    assert_raises(StripeModelMapper::UnsupportedModelError) do
      StripeModelMapper.to_stripe("gemma3")
    end
  end

  test "raises UnsupportedModelError for llama3" do
    assert_raises(StripeModelMapper::UnsupportedModelError) do
      StripeModelMapper.to_stripe("llama3")
    end
  end

  test "raises UnsupportedModelError for unknown model" do
    assert_raises(StripeModelMapper::UnsupportedModelError) do
      StripeModelMapper.to_stripe("some-unknown-model")
    end
  end

  # === supported? tests ===

  test "supported? returns true for known models" do
    assert StripeModelMapper.supported?("default")
    assert StripeModelMapper.supported?("claude-sonnet-4-20250514")
    assert StripeModelMapper.supported?("claude-haiku-4")
    assert StripeModelMapper.supported?("gpt-4o")
  end

  test "supported? returns false for Ollama models" do
    assert_not StripeModelMapper.supported?("deepseek-r1")
    assert_not StripeModelMapper.supported?("gemma3")
    assert_not StripeModelMapper.supported?("llama3")
  end

  test "supported? returns false for unknown models" do
    assert_not StripeModelMapper.supported?("totally-unknown")
  end
end
