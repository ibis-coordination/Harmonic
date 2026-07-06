# typed: false
require "test_helper"

class StripeGatewayModelMapperTest < ActiveSupport::TestCase
  test "maps blank and default to the gateway default model" do
    assert_equal "anthropic/claude-sonnet-4.6", StripeGatewayModelMapper.map(nil)
    assert_equal "anthropic/claude-sonnet-4.6", StripeGatewayModelMapper.map("")
    assert_equal "anthropic/claude-sonnet-4.6", StripeGatewayModelMapper.map("default")
  end

  test "passes provider/model names through unchanged" do
    assert_equal "anthropic/claude-sonnet-4.6", StripeGatewayModelMapper.map("anthropic/claude-sonnet-4.6")
    assert_equal "anthropic/claude-haiku-4.5", StripeGatewayModelMapper.map("anthropic/claude-haiku-4.5")
    assert_equal "anthropic/claude-opus-4.7", StripeGatewayModelMapper.map("anthropic/claude-opus-4.7")
    assert_equal "openai/gpt-4o", StripeGatewayModelMapper.map("openai/gpt-4o")
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

  test "raises UnmappedModelError for retired dashed aliases" do
    # These were LiteLLM-only aliases before model names were unified on the
    # gateway's provider/model scheme. Stored configs were migrated; a stale
    # name arriving here should fail loudly, not silently translate.
    assert_raises(StripeGatewayModelMapper::UnmappedModelError) { StripeGatewayModelMapper.map("claude-sonnet-4") }
    assert_raises(StripeGatewayModelMapper::UnmappedModelError) { StripeGatewayModelMapper.map("gpt-4o") }
  end
end
