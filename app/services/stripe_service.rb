# typed: true
# frozen_string_literal: true

class StripeService
  extend T::Sig

  class SyncResult < T::Struct
    const :success, T::Boolean
    const :charged_cents, T.nilable(Integer), default: nil
    # Human-readable error message when success is false. Callers should
    # surface this to the user (don't claim the action succeeded if it
    # didn't actually update Stripe).
    const :error, T.nilable(String), default: nil
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
      # Offer cards the customer already saved (e.g. via a credit top-up)
      # instead of asking them to type the number again. "limited" includes
      # cards Stripe saved automatically for subscription renewals.
      saved_payment_method_options: { allow_redisplay_filters: ["always", "limited"] },
      success_url: success_url,
      cancel_url: cancel_url,
    )

    T.must(session.url)
  end

  # Recalculate and update the Stripe subscription quantity for a user.
  # Sums all billable resources across ALL tenants (one subscription per user).
  # Returns a SyncResult — callers should ALWAYS check .success and surface
  # .error to the user rather than reporting success unconditionally.
  #
  # Behavior:
  # - No active subscription: no-op, success.
  # - billable_quantity == 0 + active subscription: cancel the subscription
  #   and mark the local StripeCustomer inactive. (Previously short-circuited,
  #   leaving the user being charged $3/mo for nothing — see test
  #   "cancels Stripe subscription when new_quantity drops to zero".)
  # - billable_quantity > 0: update the subscription item quantity. Charge
  #   prorated invoice on increase; Stripe applies a credit on decrease.
  # - Stripe API error: returns success: false with a human-readable error.
  sig { params(user: T.untyped).returns(SyncResult) }
  def self.sync_subscription_quantity!(user)
    # Admins are exempt from the $3/month subscription — their billable_quantity
    # always returns 0 regardless of resources (see User#billable_quantity).
    # Syncing would interpret that 0 as "all resources removed" and cancel any
    # subscription they hold. Admins may legitimately hold a StripeCustomer
    # record (with active or inactive subscription) for LLM credit attribution —
    # credit grants attach to the customer ID, not the subscription. Skipping
    # sync entirely preserves whatever subscription state they intentionally have.
    return SyncResult.new(success: true) if user.respond_to?(:sys_admin?) && (user.sys_admin? || user.app_admin?)

    sc = user.stripe_customer
    return SyncResult.new(success: true) unless sc&.active? && sc.stripe_subscription_id.present?

    new_quantity = user.billable_quantity

    if new_quantity == 0
      return cancel_subscription_for_zero_quantity!(sc, user)
    end

    # Retrieve the subscription to get the item ID — quantity must be set on the item, not the subscription
    subscription = Stripe::Subscription.retrieve(sc.stripe_subscription_id)

    # Check if Stripe reports the subscription as inactive (e.g. cancelled while webhook pending)
    inactive_statuses = %w[canceled unpaid incomplete_expired]
    if inactive_statuses.include?(subscription.status)
      Rails.logger.warn("[StripeService] Subscription #{sc.stripe_subscription_id} is #{subscription.status} — deactivating locally for user #{user.id}")
      sc.update!(active: false)
      deactivate_resources_for_customer(sc, reason: "Subscription #{subscription.status}")
      return SyncResult.new(success: false, error: "Stripe reports subscription as #{subscription.status}.")
    end

    item = subscription.items.data.first
    return SyncResult.new(success: true) unless item

    old_quantity = item.quantity

    # Skip if quantity hasn't changed (avoids unnecessary API calls and proration events)
    return SyncResult.new(success: true) if new_quantity == old_quantity

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

    SyncResult.new(success: true)
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeService] Failed to update subscription quantity for user #{user.id}: #{e.message}")
    SyncResult.new(success: false, error: "Billing system error: #{e.message}")
  end

  # User has dropped to zero billable resources. Cancel the Stripe
  # subscription so they actually stop being charged, and mark the local
  # StripeCustomer inactive. Leaves stripe_subscription_id in place for
  # historical reference; the active=false flag is what gates future syncs.
  # A future paid resource creation goes through BillingController#setup,
  # which creates a fresh subscription.
  #
  # prorate credits the unused remainder of the period; without it Stripe
  # also DESTROYS pending proration credits from earlier quantity decreases.
  # invoice_now sweeps those credits onto a final invoice, whose negative
  # total lands on the customer balance — automatically offsetting a future
  # resubscription (same Stripe customer is reused).
  #
  # invoice_now leaves that final invoice in DRAFT (observed live in test
  # mode), and the credit doesn't reach the customer balance until the
  # invoice finalizes. Auto-finalization is asynchronous — Stripe documents
  # "approximately one hour"; we observed minutes — so finalize explicitly
  # to ensure an immediate resubscription is offset by the credit.
  sig { params(sc: StripeCustomer, user: T.untyped).returns(SyncResult) }
  def self.cancel_subscription_for_zero_quantity!(sc, user)
    subscription = Stripe::Subscription.cancel(T.must(sc.stripe_subscription_id), { prorate: true, invoice_now: true })
    begin
      final_invoice = subscription.respond_to?(:latest_invoice) ? subscription.latest_invoice : nil
      final_invoice_id = final_invoice.is_a?(Stripe::Invoice) ? final_invoice.id : final_invoice
      Stripe::Invoice.finalize_invoice(final_invoice_id) if final_invoice_id.present?
    rescue Stripe::StripeError => e
      # Best-effort: the cancel already succeeded, and Stripe auto-finalizes
      # the draft within ~1 hour, so the credit still lands — just later.
      Rails.logger.warn("[StripeService] Could not finalize final invoice #{final_invoice_id}: #{e.message}")
    end
    sc.update!(active: false)
    Rails.logger.info("[StripeService] Cancelled subscription #{sc.stripe_subscription_id} for user #{user.id} (billable_quantity dropped to 0)")
    SyncResult.new(success: true)
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeService] Failed to cancel subscription for user #{user.id}: #{e.message}")
    SyncResult.new(success: false, error: "Billing system error: could not cancel subscription (#{e.message}).")
  end

  # Preview the prorated amount that would be charged for adding one more
  # billable unit (an agent, a paid collective, etc.). Returns cents, or nil
  # if preview fails.
  #
  # The target quantity is anchored on `billable_quantity + 1` — the same
  # basis sync_subscription_quantity! uses for the actual charge — so the
  # preview reflects what the user is charged even when the Stripe quantity
  # has drifted from the DB. (A drifted-high Stripe quantity yields a credit,
  # which we floor to $0, matching sync's skip-on-decrease behavior.)
  sig { params(user: T.untyped).returns(T.nilable(Integer)) }
  def self.preview_proration(user)
    sc = user.stripe_customer
    return nil unless sc&.active? && sc.stripe_subscription_id.present?

    subscription = Stripe::Subscription.retrieve(sc.stripe_subscription_id)
    item = subscription.items.data.first
    return nil unless item

    new_quantity = user.billable_quantity + 1

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
    # As of the Stripe gem we use (API version 2026-02-25.clover), the
    # `proration` boolean lives in the nested parent details
    # (`parent.subscription_item_details.proration` for subscription items,
    # `parent.invoice_item_details.proration` for invoice items), not at the
    # top of the line item — calling `line.proration` raises NoMethodError.
    proration_amount = 0
    preview.lines.data.each do |line|
      proration_amount += line.amount if line_is_proration?(line)
    end
    [proration_amount, 0].max
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeService] Failed to preview proration for user #{user.id}: #{e.message}")
    nil
  end

  sig { params(line: T.untyped).returns(T::Boolean) }
  def self.line_is_proration?(line)
    parent = line.parent
    return false if parent.nil?

    details = parent.subscription_item_details || parent.invoice_item_details
    !!details&.proration
  end
  private_class_method :line_is_proration?

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
      # Offer cards saved via the identity subscription ("limited") or a prior
      # top-up ("always"), and let the customer save a new card for next time —
      # payment-mode checkouts don't save cards by default.
      saved_payment_method_options: {
        allow_redisplay_filters: ["always", "limited"],
        payment_method_save: "enabled",
      },
      success_url: success_url,
      cancel_url: cancel_url,
    )

    T.must(session.url)
  end

  # Create a Stripe Billing Credit Grant for a completed checkout session.
  # Idempotent via Stripe's Idempotency-Key header keyed on the checkout session id.
  # Amount must be derived from session.amount_total, never user input.
  # Called from both the checkout return handler (synchronous) and the webhook (backup);
  # concurrent callers will resolve to the same underlying grant on Stripe's side.
  sig { params(stripe_customer: StripeCustomer, amount_cents: Integer, checkout_session_id: String).void }
  def self.create_credit_grant_from_checkout(stripe_customer:, amount_cents:, checkout_session_id:)
    Stripe::Billing::CreditGrant.create(
      {
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
      },
      { idempotency_key: "credit_grant:#{checkout_session_id}" },
    )
    Rails.logger.info("[StripeService] Created credit grant of #{amount_cents} cents for customer #{stripe_customer.stripe_id} (session #{checkout_session_id})")

    # Credits only drain if the customer is subscribed to the LLM-tokens
    # pricing plan; a failure here is logged and dispatch blocks gateway
    # usage until the next top-up retries it.
    ensure_pricing_plan_subscription!(stripe_customer)
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

  # Stripe's token-billing preview APIs (pricing plans, billing intents) are
  # v2 JSON endpoints not yet wrapped by stripe-ruby resources.
  PRICING_PLAN_API_VERSION = "2026-06-24.preview"

  # Subscribe the customer to the LLM-tokens pricing plan (STRIPE_PRICING_PLAN_ID).
  # Without this subscription, gateway usage is metered but never billed and
  # prepaid credits never drain — so dispatch refuses gateway tasks until it exists.
  # Idempotent via the stored pricing_plan_subscription_id. If the plan has an
  # amount due at subscribe time, charges the customer's default payment method
  # off-session. Returns false (logged) on missing config or Stripe errors;
  # callers treat that as "credits granted but usage billing incomplete".
  sig { params(stripe_customer: StripeCustomer).returns(T::Boolean) }
  def self.ensure_pricing_plan_subscription!(stripe_customer)
    return true if stripe_customer.pricing_plan_subscription_id.present?

    plan_id = ENV["STRIPE_PRICING_PLAN_ID"]
    if plan_id.blank?
      Rails.logger.warn("[StripeService] STRIPE_PRICING_PLAN_ID not set; cannot subscribe #{stripe_customer.stripe_id} to the pricing plan")
      return false
    end

    plan = v2_request(:get, "/v2/billing/pricing_plans/#{plan_id}")
    profile = v2_request(:post, "/v2/billing/profiles", { customer: stripe_customer.stripe_id })
    cadence = v2_request(:post, "/v2/billing/cadences", {
      payer: { billing_profile: profile.fetch("id") },
      billing_cycle: { type: "month", interval_count: 1 },
    })
    intent = v2_request(:post, "/v2/billing/intents", {
      currency: "usd",
      cadence: cadence.fetch("id"),
      actions: [{
        type: "subscribe",
        subscribe: {
          type: "pricing_plan_subscription_details",
          pricing_plan_subscription_details: {
            pricing_plan: plan_id,
            pricing_plan_version: plan.fetch("live_version"),
            component_configurations: [],
          },
        },
      }],
    })
    reserved = v2_request(:post, "/v2/billing/intents/#{intent.fetch("id")}/reserve")

    commit_params = {}
    amount_due = reserved.dig("amount_details", "total").to_i
    if amount_due.positive?
      payment_method = default_payment_method_for(stripe_customer)
      if payment_method.blank?
        Rails.logger.error("[StripeService] No default payment method for #{stripe_customer.stripe_id}; cannot pay pricing plan subscription")
        return false
      end
      payment_intent = Stripe::PaymentIntent.create(
        amount: amount_due,
        currency: "usd",
        customer: stripe_customer.stripe_id,
        payment_method: payment_method,
        off_session: true,
        confirm: true,
      )
      commit_params = { payment_intent: payment_intent.id }
    end

    v2_request(:post, "/v2/billing/intents/#{intent.fetch("id")}/commit", commit_params)

    # The commit response doesn't reference the created subscription; find it
    # via the cadence, which is unique to this call.
    subscriptions = v2_request(:get, "/v2/billing/pricing_plan_subscriptions")
    subscription = subscriptions.fetch("data", []).find { |s| s["billing_cadence"] == cadence.fetch("id") }
    if subscription.nil?
      Rails.logger.error("[StripeService] Committed billing intent #{intent.fetch("id")} but found no pricing plan subscription for cadence #{cadence.fetch("id")}")
      return false
    end

    stripe_customer.update!(pricing_plan_subscription_id: subscription.fetch("id"))
    Rails.logger.info("[StripeService] Subscribed #{stripe_customer.stripe_id} to pricing plan #{plan_id} (#{subscription.fetch("id")})")
    true
  rescue Stripe::StripeError => e
    Rails.logger.error("[StripeService] Failed to subscribe #{stripe_customer.stripe_id} to pricing plan: #{e.message}")
    false
  end

  sig { params(method: Symbol, path: String, params: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def self.v2_request(method, path, params = {})
    client = Stripe::StripeClient.new(T.must(Stripe.api_key))
    response = client.raw_request(method, path, params: params, opts: { stripe_version: PRICING_PLAN_API_VERSION })
    JSON.parse(response.http_body)
  end
  private_class_method :v2_request

  sig { params(stripe_customer: StripeCustomer).returns(T.nilable(String)) }
  def self.default_payment_method_for(stripe_customer)
    customer = Stripe::Customer.retrieve(stripe_customer.stripe_id)
    customer.invoice_settings&.default_payment_method
  end
  private_class_method :default_payment_method_for

  # Operational snapshot of the AI gateway configuration and every active
  # customer's prepaid credit balance. A nil balance means the Stripe API
  # call failed for that customer (details in the error log).
  sig { returns(T::Hash[Symbol, T.untyped]) }
  def self.gateway_health
    {
      llm_gateway_reachable: llm_gateway_reachable?,
      credit_product_configured: ENV["STRIPE_CREDIT_PRODUCT_ID"].present?,
      pricing_plan_configured: ENV["STRIPE_PRICING_PLAN_ID"].present?,
      active_customers: StripeCustomer.where(active: true).map do |customer|
        {
          stripe_id: customer.stripe_id,
          credit_balance_cents: get_credit_balance(customer),
          pricing_plan_subscribed: customer.pricing_plan_subscription_id.present?,
        }
      end,
    }
  end

  # STRIPE_GATEWAY_KEY lives on the llm-gateway service, not Rails, so health
  # probes the service instead of checking local env.
  sig { returns(T::Boolean) }
  def self.llm_gateway_reachable?
    url = URI.parse("#{ENV.fetch("LLM_GATEWAY_URL", "http://llm-gateway:4500")}/health")
    response = Net::HTTP.start(url.host, url.port, open_timeout: 2, read_timeout: 2) do |http|
      http.get(url.path)
    end
    response.is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end
  private_class_method :llm_gateway_reachable?

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

    was_active = sc.active?

    # Idempotency: skip activating if already active with this subscription
    unless was_active && sc.stripe_subscription_id == session.subscription
      sc.update!(
        stripe_subscription_id: session.subscription,
        active: true,
      )
      Rails.logger.info("[StripeService] Activated billing for customer #{session.customer}")
    end

    # If this checkout was launched from a collective upgrade flow,
    # session.metadata.collective_id is set — confirm the tier flip.
    # Scope the lookup to the customer's user via for_user_across_tenants
    # so we never confirm a collective belonging to a different user (and
    # so we stay within tenant-safe query helpers; .unscoped_for_system_job
    # isn't allowed outside jobs/migrations).
    metadata = session.respond_to?(:metadata) ? session.metadata : nil
    collective_id = metadata.respond_to?(:[]) ? metadata["collective_id"] : nil
    if collective_id.present? && sc.billable.is_a?(User)
      collective = Collective.for_user_across_tenants(sc.billable).find_by(id: collective_id)
      collective&.confirm_upgrade!
    end

    # Activate resources created before billing was set up. The synchronous
    # checkout-return path does this too, but the user may never come back
    # to the app after paying (closed tab) — the webhook is the reliable
    # path. Idempotent, so double execution is safe.
    activate_pending_resources_for(sc)

    # If the customer was previously inactive (e.g. subscription lapsed and
    # they just re-upped), restore any lapsed collectives now that billing
    # is active again.
    restore_lapsed_collectives_for(sc) if !was_active && sc.billable.is_a?(User)
  end
  private_class_method :handle_subscription_checkout_completed

  # Clear pending_billing_setup on the customer's resources and backfill
  # stripe_customer_id on agents that were created before billing existed.
  # Called from the checkout webhook, the synchronous checkout-return path
  # (BillingController), and the reconciliation job's recovery sweep.
  # Collectives no longer enter the pending state (the tier model replaced
  # creation-time billing) — clearing them heals legacy rows.
  sig { params(stripe_customer: StripeCustomer).void }
  def self.activate_pending_resources_for(stripe_customer)
    user = stripe_customer.billable
    return unless user.is_a?(User)

    pending_agents = user.ai_agents.where(pending_billing_setup: true)
    pending_agents.where(stripe_customer_id: nil).update_all(stripe_customer_id: stripe_customer.id)
    agent_count = pending_agents.update_all(pending_billing_setup: false)

    collective_count = Collective.for_user_across_tenants(user)
      .where(pending_billing_setup: true)
      .update_all(pending_billing_setup: false)

    return if agent_count.zero? && collective_count.zero?

    Rails.logger.info(
      "[StripeService] Recovered #{agent_count} pending agent(s) and #{collective_count} pending collective(s) for user #{user.id}"
    )
  end

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

    # If subscription transitioned to inactive (canceled, unpaid), suspend
    # agents and mark paid collectives as lapsed (preserves config so the
    # owner can restore instantly by fixing billing).
    if was_active && !now_active
      deactivate_resources_for_customer(sc, reason: "Subscription #{subscription.status}")
    end

    # If subscription transitioned to active (owner re-upped after lapse),
    # restore lapsed collectives — matches the user expectation that fixing
    # the card resumes the paid plan with no extra clicks.
    if !was_active && now_active && sc.billable.is_a?(User)
      restore_lapsed_collectives_for(sc)
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
  #
  # CROSS-TENANT SCOPE, BY DESIGN: a single Stripe customer covers the user's
  # activity across every billing-enabled tenant they belong to (billing is
  # user-scoped, not tenant-scoped — see `User#billing_tenant_ids`). A webhook
  # that disables billing therefore deactivates the user's agents and
  # collectives in every billing-enabled tenant, not only the tenant that
  # "triggered" the event. This is intentional so a single payment failure
  # doesn't leave active infrastructure running elsewhere.
  sig { params(stripe_customer: StripeCustomer, reason: String).void }
  def self.deactivate_resources_for_customer(stripe_customer, reason:)
    user = stripe_customer.billable
    return unless user.is_a?(User) && user.human?

    billing_tenant_ids = user.billing_tenant_ids

    # Suspend agents on billing-enabled tenants only. Exempt agents need no
    # subscription, so losing it doesn't touch them.
    suspended_count = 0
    user.ai_agents
      .joins(:tenant_users)
      .where(tenant_users: { tenant_id: billing_tenant_ids })
      .where(suspended_at: nil, billing_exempt: false)
      .find_each do |agent|
      agent.suspend!(by: user, reason: reason, skip_billing_sync: true)
      suspended_count += 1
    end
    Rails.logger.info("[StripeService] Suspended #{suspended_count} agents for user #{user.id}: #{reason}") if suspended_count > 0

    # Mark paid collectives as lapsed on billing-enabled tenants only.
    # Lapse just flips the tier column — runtime gates short-circuit on
    # paid_tier? so feature access pauses without touching configuration.
    # Restore is instant and zero-loss once the owner fixes their billing.
    # Exempt collectives need no subscription, so they don't lapse.
    lapsed_count = 0
    Collective.for_user_across_tenants(user)
      .where(tenant_id: billing_tenant_ids, tier: Collective::TIER_PAID, archived_at: nil, billing_exempt: false)
      .find_each do |collective|
      next if collective.is_main_collective?
      collective.mark_lapsed!
      lapsed_count += 1
    end
    Rails.logger.info("[StripeService] Lapsed #{lapsed_count} collectives for user #{user.id}: #{reason}") if lapsed_count > 0
  end
  private_class_method :deactivate_resources_for_customer

  # Auto-restore all of a user's lapsed collectives to paid. Called when the
  # user's stripe_customer transitions inactive → active (subscription
  # re-created, payment fixed via portal, etc.). Matches the user
  # expectation that fixing billing resumes the paid plan with no extra
  # clicks.
  sig { params(stripe_customer: StripeCustomer).void }
  def self.restore_lapsed_collectives_for(stripe_customer)
    user = stripe_customer.billable
    return unless user.is_a?(User)

    billing_tenant_ids = user.billing_tenant_ids
    return if billing_tenant_ids.empty?

    restored_count = 0
    Collective.for_user_across_tenants(user)
      .where(tenant_id: billing_tenant_ids, tier: Collective::TIER_LAPSED, archived_at: nil)
      .find_each do |collective|
      collective.restore_from_lapsed!
      restored_count += 1
    end
    return if restored_count.zero?

    Rails.logger.info("[StripeService] Restored #{restored_count} lapsed collectives for user #{user.id}")

    # Restoring collectives raises billable_quantity above what the
    # (possibly newly created) subscription was opened with — e.g. a user
    # who resubscribes by upgrading one collective gets ALL their lapsed
    # collectives restored, but the new subscription's quantity only
    # accounted for the one. Push the corrected quantity to Stripe now
    # instead of waiting for BillingReconciliationJob to correct it.
    #
    # Safe inside a webhook: the resulting customer.subscription.updated
    # arrives with sc already active (so handle_subscription_updated won't
    # re-restore), and the quantity will already match (so the nested
    # sync_subscription_quantity! is a no-op).
    sync_subscription_quantity!(user)
  end
  private_class_method :restore_lapsed_collectives_for
end
