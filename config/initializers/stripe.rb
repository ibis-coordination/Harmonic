# frozen_string_literal: true

# Configure Stripe API key for backend operations (customer/subscription management).
# The separate STRIPE_GATEWAY_KEY is used by agent-runner for AI Gateway requests.
Stripe.api_key = ENV["STRIPE_API_KEY"] if defined?(Stripe) && ENV["STRIPE_API_KEY"].present?
