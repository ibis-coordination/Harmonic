# typed: true
# frozen_string_literal: true

require "bigdecimal"

# Per-model LLM prices from the Stripe token-billing rate card — what a user
# pays per million tokens, already marked up. Answers "how much will this model
# cost me?" in the internal-agent model selector.
#
# Fails open: a missing pricing plan or any Stripe error yields an empty hash,
# and callers simply show no prices rather than breaking. Base price and markup
# metadata on the rate rows are dropped here and never reach a view.
class GatewayModelCatalog
  extend T::Sig

  CACHE_KEY = "gateway_model_catalog"
  CACHE_TTL = 6.hours

  class << self
    extend T::Sig

    # { "anthropic/claude-sonnet-4.6" => { input_per_million: "3.90", output_per_million: "19.50" }, ... }
    sig { returns(T::Hash[String, T::Hash[Symbol, String]]) }
    def prices
      cached = Rails.cache.read(CACHE_KEY)
      return cached if cached

      result = fetch_prices
      # Never cache an empty result, so a transient Stripe failure retries next call.
      Rails.cache.write(CACHE_KEY, result, expires_in: CACHE_TTL) if result.present?
      result
    end

    sig { void }
    def refresh!
      Rails.cache.delete(CACHE_KEY)
    end

    private

    sig { returns(T::Hash[String, T::Hash[Symbol, String]]) }
    def fetch_prices
      plan_id = ENV.fetch("STRIPE_PRICING_PLAN_ID", nil)
      return {} if plan_id.blank?

      rate_card_id = rate_card_id_for(plan_id)
      return {} if rate_card_id.nil?

      collect_prices(rate_card_id)
    rescue Stripe::StripeError, JSON::ParserError => e
      Rails.logger.error("[GatewayModelCatalog] #{e.class}: #{e.message}")
      {}
    end

    sig { params(plan_id: String).returns(T.nilable(String)) }
    def rate_card_id_for(plan_id)
      components = v2_get("/v2/billing/pricing_plans/#{plan_id}/components")
      component = components.fetch("data", []).find { |c| c["type"] == "rate_card" }
      component&.dig("rate_card", "id")
    end

    sig { params(rate_card_id: String).returns(T::Hash[String, T::Hash[Symbol, String]]) }
    def collect_prices(rate_card_id)
      prices = {}
      path = T.let("/v2/billing/rate_cards/#{rate_card_id}/rates?limit=100", String)

      loop do
        page = v2_get(path)
        page.fetch("data", []).each do |rate|
          conditions = rate.dig("metered_item", "meter_segment_conditions") || []
          model = conditions.find { |c| c["dimension"] == "model" }&.dig("value")
          token_type = conditions.find { |c| c["dimension"] == "token_type" }&.dig("value")
          next if model.blank? || token_type.blank?

          per_million = per_million_dollars(rate["unit_amount"])
          next if per_million.nil?

          (prices[model] ||= {})[:"#{token_type}_per_million"] = per_million
        end

        next_url = page["next_page_url"]
        break if next_url.blank?

        # next_page_url is a full URL; raw_request wants a path — strip the origin.
        path = next_url.to_s.sub(%r{\Ahttps?://[^/]+}, "")
      end

      # Only surface models with both an input and an output price.
      prices.select { |_model, entry| entry[:input_per_million] && entry[:output_per_million] }
    end

    # unit_amount is cents per token, already marked up → dollars per million tokens.
    sig { params(unit_amount: T.untyped).returns(T.nilable(String)) }
    def per_million_dollars(unit_amount)
      return nil if unit_amount.blank?

      dollars = BigDecimal(unit_amount.to_s) * 1_000_000 / 100
      format("%.2f", dollars)
    end

    sig { params(path: String).returns(T::Hash[String, T.untyped]) }
    def v2_get(path)
      client = Stripe::StripeClient.new(T.must(Stripe.api_key))
      response = client.raw_request(:get, path, opts: { stripe_version: StripeService::PRICING_PLAN_API_VERSION })
      JSON.parse(response.http_body)
    end
  end
end
