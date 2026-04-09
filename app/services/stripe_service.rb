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
      quantity: Integer,
    ).returns(String)
  end
  def self.create_checkout_session(stripe_customer:, success_url:, cancel_url:, quantity: 1)
    session = Stripe::Checkout::Session.create(
      customer: stripe_customer.stripe_id,
      mode: "subscription",
      line_items: [
        {
          price: ENV.fetch("STRIPE_PRICE_ID"),
          quantity: quantity,
        },
      ],
      success_url: success_url,
      cancel_url: cancel_url,
    )

    T.must(session.url)
  end

  # Recalculate and update the Stripe subscription quantity for a user.
  # quantity = 1 (user) + active_billable_agent_count
  # No-op if user has no active subscription or is billing_exempt.
  # Returns the amount charged in cents (nil if no charge, 0 if credits covered it).
  # Rescues Stripe errors to avoid blocking user actions.
  sig { params(user: T.untyped, tenant: Tenant).returns(T.nilable(Integer)) }
  def self.sync_subscription_quantity!(user, tenant)
    return nil if user.billing_exempt?

    sc = user.stripe_customer
    return nil unless sc&.active? && sc.stripe_subscription_id.present?

    new_quantity = 1 + user.active_billable_agent_count(tenant)

    # Retrieve the subscription to get the item ID — quantity must be set on the item, not the subscription
    subscription = Stripe::Subscription.retrieve(sc.stripe_subscription_id)
    item = subscription.items.data.first
    return nil unless item

    old_quantity = item.quantity

    # Skip if quantity hasn't changed (avoids unnecessary API calls and proration events)
    return nil if new_quantity == old_quantity

    Stripe::SubscriptionItem.update(item.id, quantity: new_quantity)
    Rails.logger.info("[StripeService] Updated subscription item #{item.id} quantity from #{old_quantity} to #{new_quantity} for user #{user.id}")

    # If quantity increased, create and pay a prorated invoice immediately.
    # On decrease, Stripe automatically creates a credit that applies to the next invoice.
    if new_quantity > old_quantity
      invoice = Stripe::Invoice.create(customer: sc.stripe_id, subscription: sc.stripe_subscription_id)
      # amount_due accounts for any existing credits (e.g., from a recent decrease).
      # If credits exceed the new charge, amount_due is 0 and we skip payment.
      invoice.pay if invoice.amount_due > 0
      Rails.logger.info("[StripeService] Charged prorated invoice #{invoice.id} for #{invoice.amount_due} cents")
      return invoice.amount_due
    end

    nil
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeService] Failed to update subscription quantity for user #{user.id}: #{e.message}")
    nil
  end

  # Preview the prorated amount that would be charged if subscription quantity increased by 1.
  # Returns the amount in cents, or nil if preview fails.
  sig { params(user: T.untyped, tenant: Tenant).returns(T.nilable(Integer)) }
  def self.preview_proration(user, tenant)
    return nil if user.billing_exempt?

    sc = user.stripe_customer
    return nil unless sc&.active? && sc.stripe_subscription_id.present?

    subscription = Stripe::Subscription.retrieve(sc.stripe_subscription_id)
    item = subscription.items.data.first
    return nil unless item

    new_quantity = item.quantity + 1

    preview = T.let(
      Stripe::Invoice.create_preview(
        customer: sc.stripe_id,
        subscription: sc.stripe_subscription_id,
        subscription_details: {
          items: [{ id: item.id, quantity: new_quantity }],
        },
      ),
      T.untyped,
    )

    # Sum only proration line items (exclude the next recurring charge).
    # Recurring lines match "N × Product (at $X / month)".
    proration_amount = 0
    preview.lines.data.each do |line|
      is_recurring = line.description.to_s.match?(/\d+ .+ \(at \$/)
      proration_amount += line.amount unless is_recurring
    end
    [proration_amount, 0].max
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeService] Failed to preview proration for user #{user.id}: #{e.message}")
    nil
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
    now_active = active_statuses.include?(subscription.status)
    was_active = sc.active
    sc.update!(active: now_active)
    Rails.logger.info("[StripeService] Subscription #{subscription.id} status=#{subscription.status} active=#{sc.active}")

    # If subscription transitioned to inactive (canceled, unpaid), suspend all agents
    if was_active && !now_active
      suspend_agents_for_customer(sc, reason: "Subscription #{subscription.status}")
    end
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

    suspend_agents_for_customer(sc, reason: "Subscription deleted")
  end
  private_class_method :handle_subscription_deleted

  sig { params(invoice: T.untyped).void }
  def self.handle_payment_failed(invoice)
    Rails.logger.warn("[StripeService] Payment failed for customer #{invoice.customer}")
  end
  private_class_method :handle_payment_failed

  # Suspend all agents owned by the billing customer's user.
  # Revokes API tokens (blocking external agents) and prevents task execution.
  sig { params(stripe_customer: StripeCustomer, reason: String).void }
  def self.suspend_agents_for_customer(stripe_customer, reason:)
    user = stripe_customer.billable
    return unless user.is_a?(User) && user.human?

    suspended_count = 0
    user.ai_agents.where(suspended_at: nil).find_each do |agent|
      agent.suspend!(by: user, reason: reason, skip_billing_sync: true)
      suspended_count += 1
    end
    Rails.logger.info("[StripeService] Suspended #{suspended_count} agents for user #{user.id}: #{reason}") if suspended_count > 0
  end
  private_class_method :suspend_agents_for_customer
end
