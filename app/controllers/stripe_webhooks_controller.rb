# typed: true
# frozen_string_literal: true

# Receives Stripe webhook events.
# Inherits from ActionController::Base to skip all ApplicationController middleware
# (authentication, tenant scoping, CSRF protection).
class StripeWebhooksController < ActionController::Base
  extend T::Sig

  skip_forgery_protection

  sig { void }
  def receive
    payload = request.body.read
    sig_header = request.env["HTTP_STRIPE_SIGNATURE"]

    unless sig_header.present?
      head :bad_request
      return
    end

    webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"]
    unless webhook_secret.present?
      Rails.logger.error("[StripeWebhooks] STRIPE_WEBHOOK_SECRET is not configured")
      head :internal_server_error
      return
    end

    begin
      event = Stripe::Webhook.construct_event(
        payload,
        sig_header,
        webhook_secret,
      )
    rescue JSON::ParserError, Stripe::SignatureVerificationError => e
      Rails.logger.warn("[StripeWebhooks] Invalid webhook: #{e.message}")
      head :bad_request
      return
    end

    StripeService.handle_webhook_event(event)
    head :ok
  end
end
