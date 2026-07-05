# typed: false
require "test_helper"

class StripeGatewayModelMapperTest < ActiveSupport::TestCase
  test "maps LiteLLM claude names to Stripe provider/model format" do
    assert_equal "anthropic/claude-sonnet-4.6", StripeGatewayModelMapper.map("claude-sonnet-4")
    assert_equal "anthropic/claude-haiku-4.5", StripeGatewayModelMapper.map("claude-haiku-4")
    assert_equal "anthropic/claude-opus-4.7", StripeGatewayModelMapper.map("claude-opus-4")
  end

  test "maps gpt-4o to openai provider format" do
    assert_equal "openai/gpt-4o", StripeGatewayModelMapper.map("gpt-4o")
  end

  test "maps blank and default to the gateway default model" do
    assert_equal "anthropic/claude-sonnet-4.6", StripeGatewayModelMapper.map(nil)
    assert_equal "anthropic/claude-sonnet-4.6", StripeGatewayModelMapper.map("")
    assert_equal "anthropic/claude-sonnet-4.6", StripeGatewayModelMapper.map("default")
  end

  test "passes through names already in provider/model format" do
    assert_equal "anthropic/claude-sonnet-4.6", StripeGatewayModelMapper.map("anthropic/claude-sonnet-4.6")
    assert_equal "openai/gpt-4o-mini", StripeGatewayModelMapper.map("openai/gpt-4o-mini")
  end

  test "raises UnmappedModelError for models the gateway cannot proxy" do
    error = assert_raises(StripeGatewayModelMapper::UnmappedModelError) do
      StripeGatewayModelMapper.map("trinity-large-thinking")
    end
    assert_includes error.message, "trinity-large-thinking"

    assert_raises(StripeGatewayModelMapper::UnmappedModelError) { StripeGatewayModelMapper.map("llama3") }
    assert_raises(StripeGatewayModelMapper::UnmappedModelError) { StripeGatewayModelMapper.map("deepseek-r1") }
  end
end
