# typed: true
# frozen_string_literal: true

class StripeService
  extend T::Sig

  # Find or create a StripeCustomer record for the given billable (User, Collective, etc.)
  # Uses the DB unique index on [billable_type, billable_id] as a concurrency guard.
  sig { params(billable: T.untyped).returns(StripeCustomer) }
  def self.find_or_create_customer(billable)
    # Return existing record if present
    existing = billable.stripe_customer
    return existing if existing

    # Create Stripe customer via API
    stripe_customer = Stripe::Customer.create(
      email: billable.respond_to?(:email) ? billable.email : nil,
      name: billable.respond_to?(:display_name) ? billable.display_name : billable.to_s,
      metadata: {
        billable_type: billable.class.name,
        billable_id: billable.id,
      },
    )

    # Create local record (DB unique constraint prevents duplicates)
    StripeCustomer.create!(
      billable: billable,
      stripe_id: stripe_customer.id,
      active: false,
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # Race condition or stale cache: another call created the record first
    raise e unless e.is_a?(ActiveRecord::RecordNotUnique) ||
      e.message.include?("already been taken")

    T.must(billable.reload.stripe_customer)
  end

  # Create a Stripe Checkout Session for the $3/month account subscription.
  # Uses the legacy line_items + Price API (stable, fully documented).
  # Returns the checkout URL for redirect.
  sig do
    params(
      stripe_customer: StripeCustomer,
      success_url: String,
      cancel_url: String,
    ).returns(String)
  end
  def self.create_checkout_session(stripe_customer:, success_url:, cancel_url:)
    session = Stripe::Checkout::Session.create(
      customer: stripe_customer.stripe_id,
      mode: "subscription",
      line_items: [
        {
          price: ENV.fetch("STRIPE_PRICE_ID"),
          quantity: 1,
        },
      ],
      success_url: success_url,
      cancel_url: cancel_url,
    )

    T.must(session.url)
  end

  # Create a Stripe Billing Portal session.
  # Returns the portal URL for redirect.
  sig { params(stripe_customer: StripeCustomer, return_url: String).returns(String) }
  def self.create_portal_session(stripe_customer:, return_url:)
    session = Stripe::BillingPortal::Session.create(
      customer: stripe_customer.stripe_id,
      return_url: return_url,
    )

    session.url
  end

  # Handle a verified Stripe webhook event.
  sig { params(event: T.untyped).void }
  def self.handle_webhook_event(event)
    case event.type
    when "checkout.session.completed"
      handle_checkout_completed(event.data.object)
    when "customer.subscription.updated"
      handle_subscription_updated(event.data.object)
    when "customer.subscription.deleted"
      handle_subscription_deleted(event.data.object)
    when "invoice.payment_failed"
      handle_payment_failed(event.data.object)
    else
      Rails.logger.info("[StripeService] Ignoring unhandled event type: #{event.type}")
    end
  end

  sig { params(session: T.untyped).void }
  def self.handle_checkout_completed(session)
    sc = StripeCustomer.find_by(stripe_id: session.customer)
    unless sc
      Rails.logger.warn("[StripeService] checkout.session.completed: No StripeCustomer found for #{session.customer}")
      return
    end

    sc.update!(
      stripe_subscription_id: session.subscription,
      active: true,
    )
    Rails.logger.info("[StripeService] Activated billing for customer #{session.customer}")
  end
  private_class_method :handle_checkout_completed

  sig { params(subscription: T.untyped).void }
  def self.handle_subscription_updated(subscription)
    sc = StripeCustomer.find_by(stripe_id: subscription.customer)
    unless sc
      Rails.logger.warn("[StripeService] customer.subscription.updated: No StripeCustomer found for #{subscription.customer}")
      return
    end

    active_statuses = %w[active trialing past_due]
    sc.update!(active: active_statuses.include?(subscription.status))
    Rails.logger.info("[StripeService] Subscription #{subscription.id} status=#{subscription.status} active=#{sc.active}")
  end
  private_class_method :handle_subscription_updated

  sig { params(subscription: T.untyped).void }
  def self.handle_subscription_deleted(subscription)
    sc = StripeCustomer.find_by(stripe_id: subscription.customer)
    unless sc
      Rails.logger.warn("[StripeService] customer.subscription.deleted: No StripeCustomer found for #{subscription.customer}")
      return
    end

    sc.update!(active: false)
    Rails.logger.info("[StripeService] Deactivated billing for customer #{subscription.customer}")
  end
  private_class_method :handle_subscription_deleted

  sig { params(invoice: T.untyped).void }
  def self.handle_payment_failed(invoice)
    Rails.logger.warn("[StripeService] Payment failed for customer #{invoice.customer}")
  end
  private_class_method :handle_payment_failed
end
