# typed: true
# frozen_string_literal: true

module LLMGateway
  # Estimates the cost of a billed LLM call in cents from the same
  # user-facing per-million-token prices the model selector shows
  # (GatewayModelCatalog, sourced from the Stripe rate card). An estimate —
  # Stripe's metering is the billing source of truth; unpriced models
  # estimate nil rather than guessing.
  class UsageCost
    extend T::Sig

    sig { params(model: T.nilable(String), input_tokens: Integer, output_tokens: Integer).returns(T.nilable(BigDecimal)) }
    def self.estimate_cents(model:, input_tokens:, output_tokens:)
      return nil if model.blank?

      prices = GatewayModelCatalog.prices[model]
      return nil if prices.nil?

      input_rate = BigDecimal(prices.fetch(:input_per_million))
      output_rate = BigDecimal(prices.fetch(:output_per_million))
      dollars = ((input_rate * input_tokens) + (output_rate * output_tokens)) / 1_000_000
      dollars * 100
    rescue ArgumentError, KeyError => e
      Rails.logger.error("[LLMGateway::UsageCost] Unusable catalog prices for #{model}: #{e.message}")
      nil
    end
  end
end
