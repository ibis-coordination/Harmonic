# typed: false
# frozen_string_literal: true

namespace :billing do
  desc "Report Stripe AI Gateway config status and active customers' credit balances"
  task gateway_health: :environment do
    report = StripeService.gateway_health

    puts "STRIPE_GATEWAY_KEY:       #{report[:gateway_key_present] ? "present" : "MISSING"}"
    puts "STRIPE_CREDIT_PRODUCT_ID: #{report[:credit_product_configured] ? "present" : "MISSING"}"
    puts "STRIPE_PRICING_PLAN_ID:   #{report[:pricing_plan_configured] ? "present" : "MISSING"}"
    puts "Active billing customers: #{report[:active_customers].size}"
    report[:active_customers].each do |customer|
      balance = customer[:credit_balance_cents]
      display = balance.nil? ? "BALANCE LOOKUP FAILED" : format("$%.2f", balance / 100.0)
      plan = customer[:pricing_plan_subscribed] ? "" : " [NO PRICING PLAN SUBSCRIPTION]"
      puts "  #{customer[:stripe_id]}: #{display}#{plan}"
    end
  end

  desc "Refresh the cached per-model rate catalog (GatewayModelCatalog) from the live rate card"
  task refresh_model_catalog: :environment do
    GatewayModelCatalog.refresh!
    prices = GatewayModelCatalog.prices
    puts "Refreshed model catalog: #{prices.size} model(s) priced."
    prices.sort.each do |model, rate|
      puts "  #{model.ljust(38)} input $#{rate[:input_per_million].to_s.ljust(8)} output $#{rate[:output_per_million]} per M tokens"
    end
    puts "  (empty — check STRIPE_PRICING_PLAN_ID and Stripe connectivity)" if prices.empty?
  end
end
