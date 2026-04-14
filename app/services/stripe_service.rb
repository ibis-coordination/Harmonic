# typed: true
# frozen_string_literal: true

class StripeService
  extend T::Sig

  class SyncResult < T::Struct
    const :success, T::Boolean
    const :charged_cents, T.nilable(Integer)
  end

  # Find or create a StripeCustomer record for the given billable (User, Collective, etc.)
  # Uses an advisory lock to prevent concurrent Stripe API calls that would create
  # orphaned Stripe customer objects, plus a DB unique index as a safety net.
  sig { params(billable: T.untyped).returns(StripeCustomer) }
  def self.find_or_create_customer(billable)
    # Return existing record if present
    existing = billable.stripe_customer
    return existing if existing

    # Advisory lock keyed on billable to serialize customer creation
    lock_key = "stripe_customer_create_#{billable.class.name}_#{billable.id}"
    StripeCustomer.transaction do
      ActiveRecord::Base.connection.execute(
        "SELECT pg_advisory_xact_lock(hashtext(#{ActiveRecord::Base.connection.quote(lock_key)}))",
      )

      # Re-check after acquiring lock (another request may have created it)
      already_created = billable.reload.stripe_customer
      return already_created if already_created

      # Create Stripe customer via API
      stripe_customer = Stripe::Customer.create(
        email: billable.respond_to?(:email) ? billable.email : nil,
        name: billable.respond_to?(:display_name) ? billable.display_name : billable.to_s,
        metadata: {
          billable_type: billable.class.name,
          billable_id: billable.id,
        },
      )

      # Create local record (DB unique constraint as safety net)
      StripeCustomer.create!(
        billable: billable,
        stripe_id: stripe_customer.id,
        active: false,
      )
    end
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
  # Sums all billable resources across ALL tenants (one subscription per user).
  # No-op if user has no active subscription, or if computed quantity is 0.
  # Returns a SyncResult with success status and optional charged_cents.
  # Rescues Stripe errors to avoid blocking user actions.
  sig { params(user: T.untyped).returns(SyncResult) }
  def self.sync_subscription_quantity!(user)
    sc = user.stripe_customer
    return SyncResult.new(success: true, charged_cents: nil) unless sc&.active? && sc.stripe_subscription_id.present?

    new_quantity = user.billable_quantity

    # Stripe doesn't allow quantity 0 on a subscription item — skip if nothing to bill
    return SyncResult.new(success: true, charged_cents: nil) if new_quantity == 0

    # Retrieve the subscription to get the item ID — quantity must be set on the item, not the subscription
    subscription = Stripe::Subscription.retrieve(sc.stripe_subscription_id)

    # Check if Stripe reports the subscription as inactive (e.g. cancelled while webhook pending)
    inactive_statuses = %w[canceled unpaid incomplete_expired]
    if inactive_statuses.include?(subscription.status)
      Rails.logger.warn("[StripeService] Subscription #{sc.stripe_subscription_id} is #{subscription.status} — deactivating locally for user #{user.id}")
      sc.update!(active: false)
      deactivate_resources_for_customer(sc, reason: "Subscription #{subscription.status}")
      return SyncResult.new(success: false, charged_cents: nil)
    end

    item = subscription.items.data.first
    return SyncResult.new(success: true, charged_cents: nil) unless item

    old_quantity = item.quantity

    # Skip if quantity hasn't changed (avoids unnecessary API calls and proration events)
    return SyncResult.new(success: true, charged_cents: nil) if new_quantity == old_quantity

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
      return SyncResult.new(success: true, charged_cents: invoice.amount_due)
    end

    SyncResult.new(success: true, charged_cents: nil)
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeService] Failed to update subscription quantity for user #{user.id}: #{e.message}")
    SyncResult.new(success: false, charged_cents: nil)
  end

  # Preview the prorated amount that would be charged if subscription quantity increased by 1.
  # Returns the amount in cents, or nil if preview fails.
  sig { params(user: T.untyped).returns(T.nilable(Integer)) }
  def self.preview_proration(user)
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
    proration_amount = 0
    preview.lines.data.each do |line|
      proration_amount += line.amount if line.proration
    end
    [proration_amount, 0].max
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeService] Failed to preview proration for user #{user.id}: #{e.message}")
    nil
  end

  # Create a Checkout Session for a one-time credit top-up payment.
  # Returns the checkout URL for redirect.
  sig do
    params(
      stripe_customer: StripeCustomer,
      amount_cents: Integer,
      success_url: String,
      cancel_url: String,
    ).returns(String)
  end
  def self.create_credit_topup_checkout(stripe_customer:, amount_cents:, success_url:, cancel_url:)
    max_cents = ENV.fetch("STRIPE_MAX_TOPUP_CENTS", "50000").to_i
    raise ArgumentError, "Amount must be at least 100 cents ($1.00)" if amount_cents < 100
    raise ArgumentError, "Amount exceeds maximum of #{max_cents} cents" if amount_cents > max_cents

    price = Stripe::Price.create(
      unit_amount: amount_cents,
      currency: "usd",
      product: ENV.fetch("STRIPE_CREDIT_PRODUCT_ID"),
    )

    session = Stripe::Checkout::Session.create(
      customer: stripe_customer.stripe_id,
      mode: "payment",
      line_items: [{ price: price.id, quantity: 1 }],
      metadata: { type: "credit_topup" },
      success_url: success_url,
      cancel_url: cancel_url,
    )

    T.must(session.url)
  end

  # Create a Stripe Billing Credit Grant for a completed checkout session.
  # Idempotent — skips if a grant with this checkout_session_id already exists.
  # Amount must be derived from session.amount_total, never user input.
  # Called from both the checkout return handler (synchronous) and the webhook (backup).
  sig { params(stripe_customer: StripeCustomer, amount_cents: Integer, checkout_session_id: String).void }
  def self.create_credit_grant_from_checkout(stripe_customer:, amount_cents:, checkout_session_id:)
    # Idempotency: check if we already created a grant for this checkout session.
    already_granted = T.let(false, T::Boolean)
    T.unsafe(Stripe::Billing::CreditGrant.list(customer: stripe_customer.stripe_id, limit: 100)).auto_paging_each do |grant|
      if grant.metadata&.[]("checkout_session_id") == checkout_session_id
        already_granted = true
        break
      end
    end
    if already_granted
      Rails.logger.info("[StripeService] credit_topup: Grant already exists for session #{checkout_session_id}, skipping")
      return
    end

    Stripe::Billing::CreditGrant.create(
      customer: stripe_customer.stripe_id,
      name: "Credit top-up — #{Time.current.strftime("%Y-%m-%d %H:%M")}",
      category: "paid",
      amount: {
        type: "monetary",
        monetary: {
          value: amount_cents,
          currency: "usd",
        },
      },
      applicability_config: {
        scope: { price_type: "metered" },
      },
      metadata: { checkout_session_id: checkout_session_id },
    )
    Rails.logger.info("[StripeService] Created credit grant of #{amount_cents} cents for customer #{stripe_customer.stripe_id}")
  end

  # Fetch the available credit balance for a Stripe customer.
  # Returns the balance in cents, or nil if the API call fails.
  sig { params(stripe_customer: StripeCustomer).returns(T.nilable(Integer)) }
  def self.get_credit_balance(stripe_customer)
    summary = Stripe::Billing::CreditBalanceSummary.retrieve(
      { customer: stripe_customer.stripe_id, filter: { type: "applicability_scope", applicability_scope: { price_type: "metered" } } },
    )
    # Balance is returned in monetary amount (cents)
    balance = summary.balances&.first
    return 0 unless balance

    balance.available_balance&.monetary&.value || 0
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeService] Failed to fetch credit balance for #{stripe_customer.stripe_id}: #{e.message}")
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
    # Disambiguate by session mode
    if session.mode == "payment" && session.metadata&.[]("type") == "credit_topup"
      handle_credit_topup_completed(session)
    else
      handle_subscription_checkout_completed(session)
    end
  end
  private_class_method :handle_checkout_completed

  sig { params(session: T.untyped).void }
  def self.handle_subscription_checkout_completed(session)
    sc = StripeCustomer.find_by(stripe_id: session.customer)
    unless sc
      Rails.logger.warn("[StripeService] checkout.session.completed: No StripeCustomer found for #{session.customer}")
      return
    end

    # Idempotency: skip if already activated with this subscription
    if sc.active? && sc.stripe_subscription_id == session.subscription
      Rails.logger.info("[StripeService] checkout.session.completed: Already active for #{session.customer}, skipping")
      return
    end

    sc.update!(
      stripe_subscription_id: session.subscription,
      active: true,
    )
    Rails.logger.info("[StripeService] Activated billing for customer #{session.customer}")
  end
  private_class_method :handle_subscription_checkout_completed

  sig { params(session: T.untyped).void }
  def self.handle_credit_topup_completed(session)
    sc = StripeCustomer.find_by(stripe_id: session.customer)
    unless sc
      Rails.logger.warn("[StripeService] credit_topup: No StripeCustomer found for #{session.customer}")
      return
    end

    amount_cents = session.amount_total
    unless amount_cents && amount_cents > 0
      Rails.logger.warn("[StripeService] credit_topup: Invalid amount_total for session #{session.id}")
      return
    end

    create_credit_grant_from_checkout(
      stripe_customer: sc,
      amount_cents: amount_cents,
      checkout_session_id: session.id,
    )
  end
  private_class_method :handle_credit_topup_completed

  sig { params(subscription: T.untyped).void }
  def self.handle_subscription_updated(subscription)
    sc = StripeCustomer.find_by(stripe_id: subscription.customer)
    unless sc
      Rails.logger.warn("[StripeService] customer.subscription.updated: No StripeCustomer found for #{subscription.customer}")
      return
    end

    # Ignore updates for a subscription that no longer matches the current one
    # (e.g., user resubscribed and this is a stale webhook for the old subscription)
    if sc.stripe_subscription_id.present? && sc.stripe_subscription_id != subscription.id
      Rails.logger.info("[StripeService] Ignoring update for old subscription #{subscription.id} (current: #{sc.stripe_subscription_id})")
      return
    end

    active_statuses = %w[active trialing past_due]
    now_active = active_statuses.include?(subscription.status)
    was_active = sc.active
    sc.update!(active: now_active)
    Rails.logger.info("[StripeService] Subscription #{subscription.id} status=#{subscription.status} active=#{sc.active}")

    # If subscription transitioned to inactive (canceled, unpaid), suspend all agents
    if was_active && !now_active
      deactivate_resources_for_customer(sc, reason: "Subscription #{subscription.status}")
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

    # Ignore deletes for a subscription that no longer matches the current one
    if sc.stripe_subscription_id.present? && sc.stripe_subscription_id != subscription.id
      Rails.logger.info("[StripeService] Ignoring delete for old subscription #{subscription.id} (current: #{sc.stripe_subscription_id})")
      return
    end

    # Idempotency: skip deactivation if already inactive
    was_active = sc.active?
    unless sc.active? == false
      sc.update!(active: false)
    end
    Rails.logger.info("[StripeService] Deactivated billing for customer #{subscription.customer}")

    deactivate_resources_for_customer(sc, reason: "Subscription deleted") if was_active
  end
  private_class_method :handle_subscription_deleted

  sig { params(invoice: T.untyped).void }
  def self.handle_payment_failed(invoice)
    Rails.logger.warn("[StripeService] Payment failed for customer #{invoice.customer}")
  end
  private_class_method :handle_payment_failed

  # Suspend all agents and archive all collectives owned by the billing customer's user.
  # Revokes API tokens (blocking external agents) and prevents task/automation execution.
  sig { params(stripe_customer: StripeCustomer, reason: String).void }
  def self.deactivate_resources_for_customer(stripe_customer, reason:)
    user = stripe_customer.billable
    return unless user.is_a?(User) && user.human?

    billing_tenant_ids = user.billing_tenant_ids

    # Suspend agents on billing-enabled tenants only
    suspended_count = 0
    user.ai_agents
      .joins(:tenant_users)
      .where(tenant_users: { tenant_id: billing_tenant_ids })
      .where(suspended_at: nil)
      .find_each do |agent|
      agent.suspend!(by: user, reason: reason, skip_billing_sync: true)
      suspended_count += 1
    end
    Rails.logger.info("[StripeService] Suspended #{suspended_count} agents for user #{user.id}: #{reason}") if suspended_count > 0

    # Archive non-main collectives on billing-enabled tenants only
    archived_count = 0
    Collective.for_user_across_tenants(user)
      .where(tenant_id: billing_tenant_ids, archived_at: nil)
      .find_each do |collective|
      next if collective.is_main_collective?
      collective.archive!
      archived_count += 1
    end
    Rails.logger.info("[StripeService] Archived #{archived_count} collectives for user #{user.id}: #{reason}") if archived_count > 0
  end
  private_class_method :deactivate_resources_for_customer
end
