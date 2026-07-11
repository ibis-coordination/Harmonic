# typed: false

require "test_helper"

module LLMGateway
  class UsageCostTest < ActiveSupport::TestCase
    PRICES = {
      "anthropic/claude-sonnet-4.6" => { input_per_million: "3.00", output_per_million: "15.00" },
    }.freeze

    test "estimates cents from the catalog's per-million prices" do
      GatewayModelCatalog.stub :prices, PRICES do
        cents = UsageCost.estimate_cents(model: "anthropic/claude-sonnet-4.6", input_tokens: 812, output_tokens: 344)
        assert_in_delta 0.7596, cents.to_f, 0.0001
      end
    end

    test "zero tokens cost zero" do
      GatewayModelCatalog.stub :prices, PRICES do
        assert_equal 0, UsageCost.estimate_cents(model: "anthropic/claude-sonnet-4.6", input_tokens: 0, output_tokens: 0)
      end
    end

    test "an unpriced model estimates nil" do
      GatewayModelCatalog.stub :prices, PRICES do
        assert_nil UsageCost.estimate_cents(model: "unknown/model", input_tokens: 10, output_tokens: 10)
      end
    end

    test "a blank model estimates nil" do
      GatewayModelCatalog.stub :prices, PRICES do
        assert_nil UsageCost.estimate_cents(model: nil, input_tokens: 10, output_tokens: 10)
      end
    end
  end
end
