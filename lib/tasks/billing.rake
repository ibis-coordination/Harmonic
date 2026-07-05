# typed: false
# frozen_string_literal: true

namespace :billing do
  desc "Report Stripe AI Gateway config status and active customers' credit balances"
  task gateway_health: :environment do
    report = StripeService.gateway_health

    puts "STRIPE_GATEWAY_KEY:       #{report[:gateway_key_present] ? 'present' : 'MISSING'}"
    puts "STRIPE_CREDIT_PRODUCT_ID: #{report[:credit_product_configured] ? 'present' : 'MISSING'}"
    puts "STRIPE_PRICING_PLAN_ID:   #{report[:pricing_plan_configured] ? 'present' : 'MISSING'}"
    puts "Active billing customers: #{report[:active_customers].size}"
    report[:active_customers].each do |customer|
      balance = customer[:credit_balance_cents]
      display = balance.nil? ? "BALANCE LOOKUP FAILED" : format("$%.2f", balance / 100.0)
      plan = customer[:pricing_plan_subscribed] ? "" : " [NO PRICING PLAN SUBSCRIPTION]"
      puts "  #{customer[:stripe_id]}: #{display}#{plan}"
    end
  end
end
