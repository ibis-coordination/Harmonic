# typed: false

require "test_helper"
require "webmock/minitest"

class GatewayModelCatalogTest < ActiveSupport::TestCase
  setup do
    @original_key = Stripe.api_key
    Stripe.api_key = "sk_test_fake"
    @original_plan_id = ENV.fetch("STRIPE_PRICING_PLAN_ID", nil)
    ENV["STRIPE_PRICING_PLAN_ID"] = "bpp_test_fixture"
    GatewayModelCatalog.refresh!
  end

  teardown do
    Stripe.api_key = @original_key
    ENV["STRIPE_PRICING_PLAN_ID"] = @original_plan_id
    GatewayModelCatalog.refresh!
  end

  def stub_catalog_endpoints(components: nil, rates: nil)
    components ||= file_fixture("stripe/pricing_plan_components.json").read
    rates ||= file_fixture("stripe/rate_card_rates.json").read
    stub_request(:get, "https://api.stripe.com/v2/billing/pricing_plans/bpp_test_fixture/components")
      .to_return(status: 200, body: components, headers: { "Content-Type" => "application/json" })
    stub_request(:get, %r{https://api\.stripe\.com/v2/billing/rate_cards/rcd_test_fixture/rates})
      .to_return(status: 200, body: rates, headers: { "Content-Type" => "application/json" })
  end

  test "returns marked-up per-million dollar prices keyed by gateway model name" do
    stub_catalog_endpoints

    prices = GatewayModelCatalog.prices

    assert_equal "3.90", prices["anthropic/claude-sonnet-4.6"][:input_per_million]
    assert_equal "19.50", prices["anthropic/claude-sonnet-4.6"][:output_per_million]
    assert_equal "1.30", prices["anthropic/claude-haiku-4.5"][:input_per_million]
    assert_equal "6.50", prices["anthropic/claude-haiku-4.5"][:output_per_million]
  end

  test "excludes models missing an input or output rate" do
    stub_catalog_endpoints

    assert_not_includes GatewayModelCatalog.prices.keys, "openai/only-input-model"
  end

  test "never exposes base price or markup fields" do
    stub_catalog_endpoints

    entry = GatewayModelCatalog.prices["anthropic/claude-sonnet-4.6"]
    assert_equal [:input_per_million, :output_per_million].sort, entry.keys.sort
  end

  test "returns empty hash when the pricing plan id is not configured" do
    ENV.delete("STRIPE_PRICING_PLAN_ID")

    assert_empty GatewayModelCatalog.prices
  end

  test "fails open to an empty hash on a Stripe error" do
    stub_request(:get, "https://api.stripe.com/v2/billing/pricing_plans/bpp_test_fixture/components")
      .to_return(status: 500, body: { error: { message: "boom" } }.to_json, headers: { "Content-Type" => "application/json" })

    assert_empty GatewayModelCatalog.prices
  end

  # The test env uses :null_store, so wrap a real store to exercise caching.

  test "does not cache an empty result so a transient failure can recover" do
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      GatewayModelCatalog.refresh!
      stub_request(:get, "https://api.stripe.com/v2/billing/pricing_plans/bpp_test_fixture/components")
        .to_return(status: 500, body: { error: { message: "boom" } }.to_json, headers: { "Content-Type" => "application/json" })
      assert_empty GatewayModelCatalog.prices

      WebMock.reset!
      stub_catalog_endpoints
      assert_equal "3.90", GatewayModelCatalog.prices["anthropic/claude-sonnet-4.6"][:input_per_million]
    end
  end

  test "caches a successful result" do
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      GatewayModelCatalog.refresh!
      stub_catalog_endpoints
      GatewayModelCatalog.prices

      WebMock.reset!
      # No stubs now — a second call must be served from cache, not the network.
      assert_equal "3.90", GatewayModelCatalog.prices["anthropic/claude-sonnet-4.6"][:input_per_million]
    end
  end
end
