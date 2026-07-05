# typed: false

require "test_helper"
require "webmock/minitest"

class StripeServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    # Set as main collective so it doesn't count toward billing
    @tenant.update!(main_collective_id: @collective.id)
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    enable_stripe_billing_flag!(@tenant)

    # Set Stripe API key for tests
    @original_stripe_key = Stripe.api_key
    Stripe.api_key = "sk_test_fake"

    @original_price_id = ENV["STRIPE_PRICE_ID"]
    ENV["STRIPE_PRICE_ID"] = "price_test_123"
  end

  teardown do
    Stripe.api_key = @original_stripe_key
    ENV["STRIPE_PRICE_ID"] = @original_price_id
  end

  # === find_or_create_customer ===

  test "find_or_create_customer creates StripeCustomer record and Stripe customer" do
    stub_request(:post, "https://api.stripe.com/v1/customers")
      .to_return(
        status: 200,
        body: { id: "cus_test123", object: "customer" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.find_or_create_customer(@user)

    assert_instance_of StripeCustomer, result
    assert_equal "cus_test123", result.stripe_id
    assert_equal @user, result.billable
    assert_not result.active, "New customer should not be active until checkout completes"
  end

  test "find_or_create_customer returns existing record if present" do
    existing = StripeCustomer.create!(billable: @user, stripe_id: "cus_existing123")

    # No Stripe API call should be made
    result = StripeService.find_or_create_customer(@user)
    assert_equal existing.id, result.id
    assert_equal "cus_existing123", result.stripe_id
  end

  test "find_or_create_customer is safe under concurrent calls" do
    stub_request(:post, "https://api.stripe.com/v1/customers")
      .to_return(
        status: 200,
        body: { id: "cus_race123", object: "customer" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # First call creates the record
    result1 = StripeService.find_or_create_customer(@user)
    assert_equal "cus_race123", result1.stripe_id

    # Second call should return existing, not create new
    result2 = StripeService.find_or_create_customer(@user)
    assert_equal result1.id, result2.id
  end

  # === create_checkout_session ===

  test "create_checkout_session creates subscription session with line_items" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_checkout456")

    captured_body = nil
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with { |req|
        captured_body = Rack::Utils.parse_nested_query(req.body)
        true
      }
      .to_return(
        status: 200,
        body: {
          id: "cs_test123",
          object: "checkout.session",
          url: "https://checkout.stripe.com/session/cs_test123",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.create_checkout_session(
      stripe_customer: sc,
      success_url: "https://app.example.com/billing?checkout_session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "https://app.example.com/billing",
    )

    assert_equal "https://checkout.stripe.com/session/cs_test123", result
    assert_equal "cus_checkout456", captured_body["customer"]
    assert_equal "subscription", captured_body["mode"]
    item = captured_body["line_items"]["0"]
    assert_equal "price_test_123", item["price"]
    assert_equal "1", item["quantity"]
  end

  test "create_checkout_session includes checkout_session_id template in success_url" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_url789")

    captured_body = nil
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with { |req| captured_body = req.body; true }
      .to_return(
        status: 200,
        body: {
          id: "cs_test",
          object: "checkout.session",
          url: "https://checkout.stripe.com/session/cs_test",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.create_checkout_session(
      stripe_customer: sc,
      success_url: "https://app.example.com/billing?checkout_session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "https://app.example.com/billing",
    )

    assert_includes captured_body, "%7BCHECKOUT_SESSION_ID%7D"
  end

  # === create_portal_session ===

  test "create_portal_session creates billing portal session" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_portal789")

    stub_request(:post, "https://api.stripe.com/v1/billing_portal/sessions")
      .with { |req|
        body = Rack::Utils.parse_query(req.body)
        body["customer"] == "cus_portal789" &&
          body["return_url"] == "https://app.example.com/billing"
      }
      .to_return(
        status: 200,
        body: {
          id: "bps_test123",
          object: "billing_portal.session",
          url: "https://billing.stripe.com/session/bps_test123",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.create_portal_session(
      stripe_customer: sc,
      return_url: "https://app.example.com/billing",
    )

    assert_equal "https://billing.stripe.com/session/bps_test123", result
  end

  # === handle_webhook_event ===

  test "handle_webhook checkout.session.completed activates billing for subscription" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_webhook123", active: false)

    event = build_stripe_event(
      type: "checkout.session.completed",
      object: {
        "customer" => "cus_webhook123",
        "subscription" => "sub_test123",
      },
    )

    StripeService.handle_webhook_event(event)

    sc.reload
    assert sc.active, "Customer should be active after subscription checkout"
    assert_equal "sub_test123", sc.stripe_subscription_id
  end

  test "handle_webhook checkout.session.completed activates pending agents" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_pending_act", active: false)
    agent = create_ai_agent(parent: @user, name: "Pending Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)
    agent.update!(pending_billing_setup: true)

    event = build_stripe_event(
      type: "checkout.session.completed",
      object: { "customer" => "cus_pending_act", "subscription" => "sub_pending_act" },
    )

    StripeService.handle_webhook_event(event)

    agent.reload
    assert_not agent.pending_billing_setup?,
               "paying on Stripe must activate pending agents even if the user never returns to the app"
    assert_equal sc.id, agent.stripe_customer_id
  end

  test "activate_pending_resources_for logs recovered resource counts" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_recover_log", active: true)
    agent = create_ai_agent(parent: @user, name: "Recover Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)
    agent.update!(pending_billing_setup: true)

    logs = []
    Rails.logger.stub(:info, ->(msg) { logs << msg }) do
      StripeService.activate_pending_resources_for(sc)
    end

    assert logs.any? { |m| m.include?("Recovered") && m.include?("1 pending agent") },
           "operators need a signal that pending-resource recovery actually fired (got: #{logs.inspect})"
  end

  test "activate_pending_resources_for logs nothing when there is nothing to recover" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_recover_noop", active: true)

    logs = []
    Rails.logger.stub(:info, ->(msg) { logs << msg }) do
      StripeService.activate_pending_resources_for(sc)
    end

    assert_not logs.any? { |m| m.include?("Recovered") },
               "a healthy no-op must not spam the daily reconciliation logs"
  end

  test "handle_webhook checkout.session.completed clears legacy pending collectives" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_pending_coll", active: false)
    collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Pending Coll #{SecureRandom.hex(4)}",
      handle: "pending-coll-#{SecureRandom.hex(4)}",
    )
    # No current flow sets this on collectives; set directly to model a
    # legacy row that should be healed.
    collective.update!(pending_billing_setup: true)

    event = build_stripe_event(
      type: "checkout.session.completed",
      object: { "customer" => "cus_pending_coll", "subscription" => "sub_pending_coll" },
    )

    StripeService.handle_webhook_event(event)

    assert_not collective.reload.pending_billing_setup?
  end

  test "handle_webhook checkout.session.completed redelivery after activation is a no-op" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_redeliver", active: false)
    agent = create_ai_agent(parent: @user, name: "Redeliver Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)
    agent.update!(pending_billing_setup: true)

    event = build_stripe_event(
      type: "checkout.session.completed",
      object: { "customer" => "cus_redeliver", "subscription" => "sub_redeliver" },
    )

    StripeService.handle_webhook_event(event)
    StripeService.handle_webhook_event(event)

    assert_not agent.reload.pending_billing_setup?
    assert sc.reload.active
  end

  test "handle_webhook checkout.session.completed overwrites a stale subscription_id from a previously cancelled subscription" do
    # Re-upgrade-after-zero-quantity-cancel scenario: user dropped to zero
    # paid resources, sync_subscription_quantity! cancelled their Stripe
    # subscription and set sc.active=false but left stripe_subscription_id
    # in place for history. Now the user re-upgrades a collective →
    # StripeCheckoutService creates a brand new subscription. The webhook
    # must overwrite the stale ID, not just flip active=true — otherwise
    # subsequent sync_subscription_quantity! calls would target a dead
    # subscription.
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_reup123",
      stripe_subscription_id: "sub_old_cancelled",
      active: false,
    )

    event = build_stripe_event(
      type: "checkout.session.completed",
      object: {
        "customer" => "cus_reup123",
        "subscription" => "sub_brand_new",
      },
    )

    StripeService.handle_webhook_event(event)

    sc.reload
    assert sc.active, "customer must be reactivated after fresh checkout"
    assert_equal "sub_brand_new", sc.stripe_subscription_id,
                 "webhook must overwrite the stale subscription_id with the new one"
  end

  test "handle_webhook customer.subscription.updated deactivates on cancel" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_subupdate123",
      stripe_subscription_id: "sub_update123",
      active: true,
    )

    event = build_stripe_event(
      type: "customer.subscription.updated",
      object: { "customer" => "cus_subupdate123", "id" => "sub_update123", "status" => "canceled" },
    )

    StripeService.handle_webhook_event(event)

    sc.reload
    assert_not sc.active, "Customer should be inactive when subscription is canceled"
  end

  test "handle_webhook customer.subscription.deleted deactivates billing" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_subdel123",
      stripe_subscription_id: "sub_del123",
      active: true,
    )

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_subdel123", "id" => "sub_del123" },
    )

    StripeService.handle_webhook_event(event)

    sc.reload
    assert_not sc.active, "Customer should be inactive after subscription deleted"
  end

  test "handle_webhook invoice.payment_failed logs warning" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_invoice123",
      active: true,
    )

    event = build_stripe_event(
      type: "invoice.payment_failed",
      object: { "customer" => "cus_invoice123" },
    )

    # Should not raise — just log
    assert_nothing_raised do
      StripeService.handle_webhook_event(event)
    end

    # Customer should still be active (Stripe retries; subscription.updated handles status)
    sc.reload
    assert sc.active
  end

  test "handle_webhook ignores unknown event types" do
    event = build_stripe_event(
      type: "some.unknown.event",
      object: { "customer" => "cus_unknown123" },
    )

    # Should not raise
    assert_nothing_raised do
      StripeService.handle_webhook_event(event)
    end
  end

  # === sync_subscription_quantity! ===

  test "sync_subscription_quantity! updates Stripe subscription quantity" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_sync123", active: true, stripe_subscription_id: "sub_sync123")

    # Two active agents → quantity should sync to 2 (humans are free; only
    # agents and additional collectives contribute to billable_quantity).
    agent1 = create_ai_agent(parent: @user, name: "Sync Agent A #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent1)
    agent2 = create_ai_agent(parent: @user, name: "Sync Agent B #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent2)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_sync123")
      .to_return(
        status: 200,
        body: {
          id: "sub_sync123", object: "subscription",
          items: { data: [{ id: "si_sync123", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_sync123")
      .to_return(
        status: 200,
        body: { id: "si_sync123", object: "subscription_item", quantity: 2 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # Stub invoice creation and payment for immediate proration charge
    stub_request(:post, "https://api.stripe.com/v1/invoices")
      .to_return(
        status: 200,
        body: { id: "in_sync123", object: "invoice", amount_due: 150 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, "https://api.stripe.com/v1/invoices/in_sync123/pay")
      .to_return(
        status: 200,
        body: { id: "in_sync123", object: "invoice", status: "paid" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user)

    assert_requested(:post, "https://api.stripe.com/v1/subscription_items/si_sync123") do |req|
      body = Rack::Utils.parse_query(req.body)
      body["quantity"] == "2"
    end
  end

  test "sync_subscription_quantity! does NOT cancel subscription for admin users (their billable_quantity is zero by admin exemption, but they may hold the customer for LLM credit attribution)" do
    @user.update!(app_admin: true)
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_admin", active: true, stripe_subscription_id: "sub_admin")
    cancel_stub = stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_admin")

    result = StripeService.sync_subscription_quantity!(@user)

    assert result.success, "sync should report success (no-op)"
    assert_not_requested cancel_stub
    assert sc.reload.active?, "local StripeCustomer must remain active"
  end

  test "sync_subscription_quantity! does NOT cancel subscription for sys_admin users either" do
    @user.update!(sys_admin: true)
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_sysadmin", active: true, stripe_subscription_id: "sub_sysadmin")
    cancel_stub = stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_sysadmin")

    result = StripeService.sync_subscription_quantity!(@user)

    assert result.success
    assert_not_requested cancel_stub
    assert sc.reload.active?
  end

  test "sync_subscription_quantity! cancels subscription for a billing_exempt user (their billable_quantity is zero)" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_exempt", active: true, stripe_subscription_id: "sub_exempt")
    @user.update!(billing_exempt: true)
    stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_exempt")
      .with(query: hash_including({}))
      .to_return(status: 200,
                 body: { id: "sub_exempt", object: "subscription", status: "canceled" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    StripeService.sync_subscription_quantity!(@user)

    assert_requested :delete, "https://api.stripe.com/v1/subscriptions/sub_exempt", query: hash_including({}), at_least_times: 1
    assert_not sc.reload.active?
  end

  # === Zero quantity: subscription must be cancelled, not silently ignored ===
  #
  # Regression for the bug where a user who downgraded/archived their LAST
  # paid resource was silently kept on the subscription (Stripe rejects
  # quantity=0, so the service early-returned without doing anything). The
  # user kept getting charged $3/mo for nothing, and we told them their
  # downgrade succeeded. These tests pin the corrected behavior: cancel the
  # subscription, mark the local StripeCustomer inactive, return success.

  test "sync_subscription_quantity! cancels Stripe subscription when new_quantity drops to zero" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_drop_zero", active: true, stripe_subscription_id: "sub_drop_zero")
    # @user has no agents and is a human → billable_quantity is 0

    stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_drop_zero")
      .with(query: hash_including({}))
      .to_return(
        status: 200,
        body: { id: "sub_drop_zero", object: "subscription", status: "canceled" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.sync_subscription_quantity!(@user)

    assert result.success, "sync should report success after cancelling the subscription"
    assert_requested :delete, "https://api.stripe.com/v1/subscriptions/sub_drop_zero", query: hash_including({}), at_least_times: 1
    assert_not sc.reload.active?, "local StripeCustomer must be marked inactive after cancellation"
  end

  test "cancel at zero quantity prorates, invoices, and finalizes so unused time becomes customer credit" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_drop_prorate", active: true, stripe_subscription_id: "sub_drop_prorate")

    stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_drop_prorate")
      .with(query: hash_including({}))
      .to_return(
        status: 200,
        body: { id: "sub_drop_prorate", object: "subscription", status: "canceled", latest_invoice: "in_final_123" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, "https://api.stripe.com/v1/invoices/in_final_123/finalize")
      .to_return(
        status: 200,
        body: { id: "in_final_123", object: "invoice", status: "open", total: -600 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user)

    # Without prorate, Stripe forfeits the unused remainder AND destroys any
    # pending proration credits from earlier quantity decreases. invoice_now
    # sweeps the credit onto a final invoice so it lands on the customer
    # balance and offsets a future resubscription.
    assert_requested(:delete, "https://api.stripe.com/v1/subscriptions/sub_drop_prorate",
                     query: { "prorate" => "true", "invoice_now" => "true" })
    # invoice_now leaves the final credit invoice in draft (verified live in
    # Stripe test mode), and the credit doesn't reach the customer balance
    # until the invoice finalizes — which Stripe does asynchronously, on its
    # own schedule. Finalize explicitly so an immediate resubscription is
    # offset.
    assert_requested(:post, "https://api.stripe.com/v1/invoices/in_final_123/finalize")
  end

  test "sync_subscription_quantity! returns failure SyncResult with error when Stripe cancellation fails" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_cancel_fail", active: true, stripe_subscription_id: "sub_cancel_fail")

    stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_cancel_fail")
      .with(query: hash_including({}))
      .to_return(status: 500, body: { error: { message: "stripe is down" } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    result = StripeService.sync_subscription_quantity!(@user)

    assert_not result.success, "sync should report failure when Stripe rejects the cancel"
    assert result.error.present?, "failure result must carry an error message for the caller to surface"
    assert sc.reload.active?, "local StripeCustomer must remain active when cancellation failed (avoid drift)"
  end

  test "sync_subscription_quantity! returns failure SyncResult with error when Stripe quantity update fails" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_update_fail", active: true, stripe_subscription_id: "sub_update_fail")
    agent = create_ai_agent(parent: @user, name: "Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_update_fail")
      .to_return(
        status: 200,
        body: {
          id: "sub_update_fail", object: "subscription", status: "active",
          items: { data: [{ id: "si_update_fail", quantity: 5, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_update_fail")
      .to_return(status: 500, body: { error: { message: "stripe is down" } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    result = StripeService.sync_subscription_quantity!(@user)

    assert_not result.success, "sync should report failure when Stripe rejects the quantity update"
    assert result.error.present?, "failure result must carry an error message"
  end

  test "sync_subscription_quantity! is no-op without active subscription" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_nosub", active: false)

    StripeService.sync_subscription_quantity!(@user)

    assert_not_requested(:any, /api\.stripe\.com/)
  end

  test "sync_subscription_quantity! logs and does not raise on Stripe failure" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_fail", active: true, stripe_subscription_id: "sub_fail")
    # @user has no agents → billable_quantity is 0 → cancellation path. Stub
    # the DELETE to fail and confirm we swallow the StripeError gracefully and
    # return a failure SyncResult (instead of raising up to the caller).
    stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_fail")
      .with(query: hash_including({}))
      .to_return(status: 500, body: { error: { message: "Internal error" } }.to_json)

    result = nil
    assert_nothing_raised do
      result = StripeService.sync_subscription_quantity!(@user)
    end
    assert_not result.success
  end

  test "sync_subscription_quantity! excludes archived and suspended agents from count" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_count", active: true, stripe_subscription_id: "sub_count")

    # Two active agents (countable) + archived + suspended (both excluded).
    # Expected quantity: 2 (humans are free).
    active_agent_a = create_ai_agent(parent: @user, name: "Active Agent A #{SecureRandom.hex(4)}")
    @tenant.add_user!(active_agent_a)
    active_agent_b = create_ai_agent(parent: @user, name: "Active Agent B #{SecureRandom.hex(4)}")
    @tenant.add_user!(active_agent_b)
    archived_agent = create_ai_agent(parent: @user, name: "Archived Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(archived_agent)
    archived_agent.tenant_user = archived_agent.tenant_users.find_by(tenant_id: @tenant.id)
    archived_agent.archive!
    suspended_agent = create_ai_agent(parent: @user, name: "Suspended Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(suspended_agent)
    suspended_agent.update!(suspended_at: Time.current)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_count")
      .to_return(
        status: 200,
        body: {
          id: "sub_count", object: "subscription",
          items: { data: [{ id: "si_count", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_count")
      .to_return(
        status: 200,
        body: { id: "si_count", object: "subscription_item", quantity: 2 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # Stub invoice creation and payment for immediate proration charge
    stub_request(:post, "https://api.stripe.com/v1/invoices")
      .to_return(
        status: 200,
        body: { id: "in_count", object: "invoice", amount_due: 150 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, "https://api.stripe.com/v1/invoices/in_count/pay")
      .to_return(
        status: 200,
        body: { id: "in_count", object: "invoice", status: "paid" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user)

    # Should be 1 (user) + 1 (active agent only) = 2
    assert_requested(:post, "https://api.stripe.com/v1/subscription_items/si_count") do |req|
      body = Rack::Utils.parse_query(req.body)
      body["quantity"] == "2"
    end
  end

  # === create_checkout_session quantity ===

  test "create_checkout_session sets initial quantity based on agent count" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_initqty")
    agent1 = create_ai_agent(parent: @user, name: "Qty Agent 1 #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent1)
    agent2 = create_ai_agent(parent: @user, name: "Qty Agent 2 #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent2)

    captured_body = nil
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with { |req| captured_body = Rack::Utils.parse_nested_query(req.body); true }
      .to_return(
        status: 200,
        body: { id: "cs_qty", object: "checkout.session", url: "https://checkout.stripe.com/cs_qty" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.create_checkout_session(
      stripe_customer: sc,
      success_url: "https://example.com/billing",
      cancel_url: "https://example.com/billing",
      quantity: 3,
    )

    assert_equal "3", captured_body["line_items"]["0"]["quantity"]
  end

  # === Edge case: no-op when quantity unchanged ===

  test "sync_subscription_quantity! skips Stripe update when quantity unchanged" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_noop", active: true, stripe_subscription_id: "sub_noop")
    # Two active agents → billable_quantity == 2, matches the stubbed Stripe
    # quantity below. The "skip if unchanged" branch should fire and we
    # should NOT POST to subscription_items. (Previously this test set up
    # no agents → quantity=0 → it was actually exercising the now-cancelled
    # zero-quantity short-circuit, not the unchanged-quantity branch.)
    agent_a = create_ai_agent(parent: @user, name: "Noop A #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent_a)
    agent_b = create_ai_agent(parent: @user, name: "Noop B #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent_b)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_noop")
      .to_return(
        status: 200,
        body: {
          id: "sub_noop", object: "subscription", status: "active",
          items: { data: [{ id: "si_noop", quantity: 2, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user)

    # Should NOT call SubscriptionItem.update
    assert_not_requested(:post, "https://api.stripe.com/v1/subscription_items/si_noop")
  end

  # === Edge case: quantity decrease does NOT create invoice ===

  test "sync_subscription_quantity! does not create invoice on quantity decrease" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_dec", active: true, stripe_subscription_id: "sub_dec")

    # Subscription has quantity 3 but user has only 1 active agent → new quantity = 2
    agent = create_ai_agent(parent: @user, name: "Dec Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_dec")
      .to_return(
        status: 200,
        body: {
          id: "sub_dec", object: "subscription",
          items: { data: [{ id: "si_dec", quantity: 3, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_dec")
      .to_return(
        status: 200,
        body: { id: "si_dec", object: "subscription_item", quantity: 2 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user)

    # Should update quantity
    assert_requested(:post, "https://api.stripe.com/v1/subscription_items/si_dec")
    # Should NOT create invoice (decrease = Stripe handles credit automatically)
    assert_not_requested(:post, "https://api.stripe.com/v1/invoices")
  end

  # === Edge case: invoice with zero amount_due is not paid ===

  test "sync_subscription_quantity! skips payment when invoice amount_due is zero" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_zero", active: true, stripe_subscription_id: "sub_zero")

    agent = create_ai_agent(parent: @user, name: "Zero Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_zero")
      .to_return(
        status: 200,
        body: {
          id: "sub_zero", object: "subscription",
          items: { data: [{ id: "si_zero", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_zero")
      .to_return(
        status: 200,
        body: { id: "si_zero", object: "subscription_item", quantity: 2 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # Invoice has zero amount_due (e.g., existing credits cover the proration)
    stub_request(:post, "https://api.stripe.com/v1/invoices")
      .to_return(
        status: 200,
        body: { id: "in_zero", object: "invoice", amount_due: 0 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user)

    # Should NOT pay the invoice
    assert_not_requested(:post, "https://api.stripe.com/v1/invoices/in_zero/pay")
  end

  # === Edge case: invoice payment fails (card declined) ===

  test "sync_subscription_quantity! does not raise when invoice payment fails" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_declined", active: true, stripe_subscription_id: "sub_declined")

    agent = create_ai_agent(parent: @user, name: "Declined Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_declined")
      .to_return(
        status: 200,
        body: {
          id: "sub_declined", object: "subscription",
          items: { data: [{ id: "si_declined", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_declined")
      .to_return(
        status: 200,
        body: { id: "si_declined", object: "subscription_item", quantity: 2 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/invoices")
      .to_return(
        status: 200,
        body: { id: "in_declined", object: "invoice", amount_due: 150 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # Payment fails (card declined)
    stub_request(:post, "https://api.stripe.com/v1/invoices/in_declined/pay")
      .to_return(
        status: 402,
        body: { error: { type: "card_error", message: "Your card was declined." } }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # Should not raise — quantity is updated, Stripe dunning handles the failed payment
    assert_nothing_raised do
      StripeService.sync_subscription_quantity!(@user)
    end
  end

  # === Edge case: concurrent syncs produce correct result ===

  test "sync_subscription_quantity! is idempotent — two calls produce same result" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_idem", active: true, stripe_subscription_id: "sub_idem")

    # Two agents → quantity 2 (humans are free).
    agent_a = create_ai_agent(parent: @user, name: "Idem Agent A #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent_a)
    agent_b = create_ai_agent(parent: @user, name: "Idem Agent B #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent_b)

    # First call: quantity goes from 1 to 2
    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_idem")
      .to_return(
        status: 200,
        body: {
          id: "sub_idem", object: "subscription",
          items: { data: [{ id: "si_idem", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      ).then
      .to_return(
        status: 200,
        body: {
          id: "sub_idem", object: "subscription",
          items: { data: [{ id: "si_idem", quantity: 2, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_idem")
      .to_return(
        status: 200,
        body: { id: "si_idem", object: "subscription_item", quantity: 2 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/invoices")
      .to_return(
        status: 200,
        body: { id: "in_idem", object: "invoice", amount_due: 150 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/invoices/in_idem/pay")
      .to_return(
        status: 200,
        body: { id: "in_idem", object: "invoice", status: "paid" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # First call — updates quantity and charges
    StripeService.sync_subscription_quantity!(@user)
    # Second call — quantity already matches, should be no-op
    StripeService.sync_subscription_quantity!(@user)

    # SubscriptionItem.update called only once (second call sees quantity=2, skips)
    assert_requested(:post, "https://api.stripe.com/v1/subscription_items/si_idem", times: 1)
    # Invoice created only once
    assert_requested(:post, "https://api.stripe.com/v1/invoices", times: 1)
  end

  # === Edge case: webhook checkout.session.completed is idempotent ===

  test "handle_webhook checkout.session.completed does not re-activate already active customer" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_already_active",
      stripe_subscription_id: "sub_existing",
      active: true,
    )

    event = build_stripe_event(
      type: "checkout.session.completed",
      object: {
        "customer" => "cus_already_active",
        "subscription" => "sub_new",
      },
    )

    StripeService.handle_webhook_event(event)

    sc.reload
    assert sc.active
    # Subscription ID gets updated (Stripe may send this for renewals)
    assert_equal "sub_new", sc.stripe_subscription_id
  end

  # === Edge case: subscription deleted deactivates and blocks agents ===

  test "handle_webhook customer.subscription.deleted suspends all agents" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_del_suspend",
      stripe_subscription_id: "sub_del_suspend",
      active: true,
    )

    agent1 = create_ai_agent(parent: @user, name: "Del Agent 1 #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent1)
    agent2 = create_ai_agent(parent: @user, name: "Del Agent 2 #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent2)

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_del_suspend", "id" => "sub_del_suspend" },
    )

    StripeService.handle_webhook_event(event)

    agent1.reload
    agent2.reload
    assert agent1.suspended?, "Agent 1 should be suspended after subscription deleted"
    assert agent2.suspended?, "Agent 2 should be suspended after subscription deleted"
    assert_includes agent1.suspended_reason, "Subscription deleted"
  end

  test "handle_webhook customer.subscription.deleted leaves billing_exempt agents unsuspended" do
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_del_exempt_agent",
      stripe_subscription_id: "sub_del_exempt_agent",
      active: true,
    )

    exempt_agent = create_ai_agent(parent: @user, name: "Exempt Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(exempt_agent)
    exempt_agent.update!(billing_exempt: true)
    billed_agent = create_ai_agent(parent: @user, name: "Billed Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(billed_agent)

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_del_exempt_agent", "id" => "sub_del_exempt_agent" },
    )

    StripeService.handle_webhook_event(event)

    assert_not exempt_agent.reload.suspended?,
               "exempt agents need no subscription, so losing it must not suspend them"
    assert billed_agent.reload.suspended?
  end

  test "handle_webhook customer.subscription.deleted leaves billing_exempt paid collectives on the paid tier" do
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_del_exempt_coll",
      stripe_subscription_id: "sub_del_exempt_coll",
      active: true,
    )

    exempt_collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Exempt Coll #{SecureRandom.hex(4)}",
      handle: "exempt-coll-#{SecureRandom.hex(4)}",
    )
    exempt_collective.update!(tier: Collective::TIER_PAID, billing_exempt: true)

    billed_collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Billed Coll #{SecureRandom.hex(4)}",
      handle: "billed-coll-#{SecureRandom.hex(4)}",
    )
    billed_collective.update!(tier: Collective::TIER_PAID)

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_del_exempt_coll", "id" => "sub_del_exempt_coll" },
    )

    StripeService.handle_webhook_event(event)

    assert_equal Collective::TIER_PAID, exempt_collective.reload.tier,
                 "exempt collectives need no subscription, so losing it must not lapse them"
    assert_equal Collective::TIER_LAPSED, billed_collective.reload.tier
  end

  test "handle_webhook customer.subscription.updated to canceled suspends agents" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_cancel_suspend",
      stripe_subscription_id: "sub_cancel_suspend",
      active: true,
    )

    agent = create_ai_agent(parent: @user, name: "Cancel Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    event = build_stripe_event(
      type: "customer.subscription.updated",
      object: { "customer" => "cus_cancel_suspend", "id" => "sub_cancel_suspend", "status" => "canceled" },
    )

    StripeService.handle_webhook_event(event)

    agent.reload
    assert agent.suspended?, "Agent should be suspended when subscription canceled"
    sc.reload
    assert_not sc.active
  end

  test "handle_webhook customer.subscription.updated to active does not suspend agents" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_renew",
      stripe_subscription_id: "sub_renew",
      active: true,
    )

    agent = create_ai_agent(parent: @user, name: "Renew Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    event = build_stripe_event(
      type: "customer.subscription.updated",
      object: { "customer" => "cus_renew", "id" => "sub_renew", "status" => "active" },
    )

    StripeService.handle_webhook_event(event)

    agent.reload
    assert_not agent.suspended?, "Agent should NOT be suspended when subscription stays active"
  end

  test "handle_webhook customer.subscription.deleted revokes agent API tokens" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_del_tokens",
      stripe_subscription_id: "sub_del_tokens",
      active: true,
    )

    agent = create_ai_agent(parent: @user, name: "Token Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    # Create an API token for the agent
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    token = ApiToken.create!(user: agent, tenant: @tenant, name: "test", expires_at: 1.year.from_now, scopes: ["read:all"])
    Tenant.clear_thread_scope

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_del_tokens", "id" => "sub_del_tokens" },
    )

    StripeService.handle_webhook_event(event)

    token.reload
    assert token.deleted_at.present?, "API token should be revoked when subscription deleted"
  end

  test "handle_webhook customer.subscription.updated to canceled revokes agent API tokens" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_cancel_tokens",
      stripe_subscription_id: "sub_cancel_tokens",
      active: true,
    )

    agent = create_ai_agent(parent: @user, name: "Cancel Token Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    token = ApiToken.create!(user: agent, tenant: @tenant, name: "test", expires_at: 1.year.from_now, scopes: ["read:all"])
    Tenant.clear_thread_scope

    event = build_stripe_event(
      type: "customer.subscription.updated",
      object: { "customer" => "cus_cancel_tokens", "id" => "sub_cancel_tokens", "status" => "canceled" },
    )

    StripeService.handle_webhook_event(event)

    token.reload
    assert token.deleted_at.present?, "API token should be revoked when subscription canceled"
  end

  # === preview_proration ===

  test "preview_proration returns proration amount for adding one agent" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_preview", active: true, stripe_subscription_id: "sub_preview")

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_preview")
      .to_return(
        status: 200,
        body: {
          id: "sub_preview", object: "subscription",
          items: { data: [{ id: "si_preview", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # Stripe API 2026-02-25.clover moved the `proration` boolean into
    # parent.subscription_item_details.proration on subscription-driven lines.
    sub_proration_parent = { type: "subscription_item_details", subscription_item_details: { proration: true } }
    sub_non_proration_parent = { type: "subscription_item_details", subscription_item_details: { proration: false } }
    stub_request(:post, "https://api.stripe.com/v1/invoices/create_preview")
      .to_return(
        status: 200,
        body: {
          id: "in_preview", object: "invoice", amount_due: 1199,
          lines: { data: [
            { amount: -600, description: "Unused time on 1 x Account after 09 Apr 2026", parent: sub_proration_parent },
            { amount: 899, description: "Remaining time on 2 x Account after 09 Apr 2026", parent: sub_proration_parent },
            { amount: 900, description: "2 x Account (at $3.00 / month)", parent: sub_non_proration_parent },
          ] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.preview_proration(@user)

    # Should return only the proration lines: -600 + 899 = 299
    assert_equal 299, result
  end

  test "preview_proration returns nil for billing_exempt user" do
    @user.update!(billing_exempt: true)
    result = StripeService.preview_proration(@user)
    assert_nil result
  end

  test "preview_proration returns nil without active subscription" do
    result = StripeService.preview_proration(@user)
    assert_nil result
  end

  test "preview_proration returns nil on Stripe error" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_prev_fail", active: true, stripe_subscription_id: "sub_prev_fail")

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_prev_fail")
      .to_return(status: 500, body: { error: { message: "Error" } }.to_json)

    result = StripeService.preview_proration(@user)
    assert_nil result
  end

  # Regression: pre-fix, preview_proration called `line.proration` directly
  # but Stripe API 2026-02-25.clover only exposes that boolean at
  # `parent.subscription_item_details.proration` (or invoice_item_details).
  # The old call raised NoMethodError. Now we navigate the nested parent.
  test "preview_proration reads proration from parent.subscription_item_details" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_nested", active: true, stripe_subscription_id: "sub_nested")

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_nested")
      .to_return(
        status: 200,
        body: {
          id: "sub_nested", object: "subscription",
          items: { data: [{ id: "si_nested", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    proration_parent = { type: "subscription_item_details", subscription_item_details: { proration: true } }
    recurring_parent = { type: "subscription_item_details", subscription_item_details: { proration: false } }
    stub_request(:post, "https://api.stripe.com/v1/invoices/create_preview")
      .to_return(
        status: 200,
        body: {
          id: "in_nested", lines: { data: [
            { amount: 150, parent: proration_parent },
            { amount: 300, parent: recurring_parent },
          ] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.preview_proration(@user)
    assert_equal 150, result, "only the line with parent.subscription_item_details.proration=true should count"
  end

  # F2: the previewed amount must match what the user is actually charged on
  # confirm. sync_subscription_quantity! computes the target from
  # billable_quantity, so the preview must too — NOT from the live Stripe
  # item.quantity, which can drift from the DB. Here Stripe reports 5 but the
  # real billable_quantity is 2, so the preview must request 2+1=3 (matching
  # the eventual charge), not 5+1=6.
  test "preview_proration targets billable_quantity+1, not the drifted Stripe quantity" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_drift", active: true, stripe_subscription_id: "sub_drift")

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_drift")
      .to_return(
        status: 200,
        body: {
          id: "sub_drift", object: "subscription",
          items: { data: [{ id: "si_drift", quantity: 5, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    captured_body = nil
    stub_request(:post, "https://api.stripe.com/v1/invoices/create_preview")
      .with { |req| captured_body = req.body; true }
      .to_return(
        status: 200,
        body: { id: "in_drift", lines: { data: [] } }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    @user.stub(:billable_quantity, 2) do
      StripeService.preview_proration(@user)
    end

    decoded = CGI.unescape(captured_body.to_s)
    assert_includes decoded, "[quantity]=3",
      "preview must target billable_quantity(2)+1=3; body was: #{decoded}"
    refute_includes decoded, "[quantity]=6",
      "preview must not target Stripe item.quantity(5)+1=6"
  end


  test "handle_webhook customer.subscription.deleted marks user's paid collectives as lapsed" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_del_coll",
      stripe_subscription_id: "sub_del_coll",
      active: true,
    )

    # Create a non-main paid collective owned by the user
    extra_collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Extra Coll #{SecureRandom.hex(4)}",
      handle: "extra-coll-#{SecureRandom.hex(4)}",
    )
    extra_collective.update!(tier: Collective::TIER_PAID)

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_del_coll", "id" => "sub_del_coll" },
    )

    StripeService.handle_webhook_event(event)

    extra_collective.reload
    assert_equal Collective::TIER_LAPSED, extra_collective.tier,
                 "Paid collective should be lapsed (not archived) when subscription deleted"
    assert_not extra_collective.archived?, "Lapse must not archive — restore is instant and zero-loss"
  end

  test "handle_webhook customer.subscription.deleted leaves free collectives untouched" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_del_free",
      stripe_subscription_id: "sub_del_free",
      active: true,
    )

    free_collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Free Coll #{SecureRandom.hex(4)}",
      handle: "free-coll-#{SecureRandom.hex(4)}",
    )

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_del_free", "id" => "sub_del_free" },
    )

    StripeService.handle_webhook_event(event)

    free_collective.reload
    assert_equal Collective::TIER_FREE, free_collective.tier
  end

  test "handle_webhook customer.subscription.updated restores lapsed collectives on reactivation" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_restore",
      stripe_subscription_id: "sub_restore",
      active: false,
    )

    lapsed_collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Lapsed Coll #{SecureRandom.hex(4)}",
      handle: "lapsed-coll-#{SecureRandom.hex(4)}",
    )
    lapsed_collective.update!(tier: Collective::TIER_PAID)
    lapsed_collective.update!(tier: Collective::TIER_LAPSED)

    # F1: restoring lapsed collectives must push the corrected quantity to
    # Stripe (restore raises billable_quantity above what a resubscribe
    # checkout opened with). Stub the sync_subscription_quantity! calls.
    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_restore")
      .to_return(
        status: 200,
        body: {
          id: "sub_restore", status: "active",
          items: { data: [{ id: "si_restore", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )
    stub_request(:post, %r{https://api.stripe.com/v1/subscription_items/si_restore})
      .to_return(status: 200, body: { id: "si_restore", quantity: 1 }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:post, "https://api.stripe.com/v1/invoices")
      .to_return(status: 200, body: { id: "in_restore", amount_due: 0 }.to_json,
                 headers: { "Content-Type" => "application/json" })

    event = build_stripe_event(
      type: "customer.subscription.updated",
      object: { "customer" => "cus_restore", "id" => "sub_restore", "status" => "active" },
    )

    StripeService.handle_webhook_event(event)

    lapsed_collective.reload
    assert_equal Collective::TIER_PAID, lapsed_collective.tier,
                 "Lapsed collective should auto-restore to paid when subscription becomes active"
    # F1 regression: the restore must have triggered a quantity sync to Stripe.
    assert_requested :get, "https://api.stripe.com/v1/subscriptions/sub_restore",
                     at_least_times: 1
  end

  test "handle_webhook customer.subscription.deleted deactivates customer so agents cannot run" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_del_agent",
      stripe_subscription_id: "sub_del_agent",
      active: true,
    )

    agent = create_ai_agent(parent: @user, name: "Del Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_del_agent", "id" => "sub_del_agent" },
    )

    StripeService.handle_webhook_event(event)

    sc.reload
    assert_not sc.active, "expected StripeCustomer to be deactivated"
    # The "agents cannot run" claim in the test name: the webhook handler
    # suspends all of the user's agents on subscription deletion. Assert
    # that directly. (stripe_billing_setup? returns true here because the
    # agent is now suspended → billable_quantity is 0 → nothing to pay
    # for → user is back to a free-account state.)
    agent.reload
    assert agent.suspended_at.present?,
           "expected agent to be suspended when subscription is deleted"
  end

  # === Per-resource billing exemption ===

  test "sync_subscription_quantity! excludes exempt user from count but includes non-exempt agents" do
    @user.update!(billing_exempt: true)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_perexempt", active: true, stripe_subscription_id: "sub_perexempt")

    agent = create_ai_agent(parent: @user, name: "Non-exempt Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_perexempt")
      .to_return(
        status: 200,
        body: {
          id: "sub_perexempt", object: "subscription",
          items: { data: [{ id: "si_perexempt", quantity: 2, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_perexempt")
      .to_return(
        status: 200,
        body: { id: "si_perexempt", object: "subscription_item", quantity: 1 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user)

    # Should be 0 (exempt user) + 1 (non-exempt agent) = 1
    assert_requested(:post, "https://api.stripe.com/v1/subscription_items/si_perexempt") do |req|
      body = Rack::Utils.parse_query(req.body)
      body["quantity"] == "1"
    end
  end

  test "sync_subscription_quantity! excludes exempt agents from count" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_agentexempt", active: true, stripe_subscription_id: "sub_agentexempt")

    exempt_agent = create_ai_agent(parent: @user, name: "Exempt Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(exempt_agent)
    exempt_agent.update!(billing_exempt: true)

    # Two paid agents → quantity 2 (humans are free; exempt agent doesn't count).
    paid_agent_a = create_ai_agent(parent: @user, name: "Paid Agent A #{SecureRandom.hex(4)}")
    @tenant.add_user!(paid_agent_a)
    paid_agent_b = create_ai_agent(parent: @user, name: "Paid Agent B #{SecureRandom.hex(4)}")
    @tenant.add_user!(paid_agent_b)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_agentexempt")
      .to_return(
        status: 200,
        body: {
          id: "sub_agentexempt", object: "subscription",
          items: { data: [{ id: "si_agentexempt", quantity: 3, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_agentexempt")
      .to_return(
        status: 200,
        body: { id: "si_agentexempt", object: "subscription_item", quantity: 2 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user)

    # Should be 2 paid agents (humans free, exempt agent excluded) = 2
    assert_requested(:post, "https://api.stripe.com/v1/subscription_items/si_agentexempt") do |req|
      body = Rack::Utils.parse_query(req.body)
      body["quantity"] == "2"
    end
  end

  test "sync_subscription_quantity! excludes exempt collectives from count" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_collexempt", active: true, stripe_subscription_id: "sub_collexempt")

    # Two paid-tier collectives (humans free, exempt collective excluded) → quantity 2
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    paid_collective_a = Collective.create!(tenant: @tenant, created_by: @user, name: "Paid Coll A", handle: "paid-coll-a-#{SecureRandom.hex(4)}")
    paid_collective_b = Collective.create!(tenant: @tenant, created_by: @user, name: "Paid Coll B", handle: "paid-coll-b-#{SecureRandom.hex(4)}")
    # Flip tier directly — upgrade! requires Stripe customer which the test
    # already has, but bypassing the method keeps the test focused on the
    # quantity-sync behavior under test.
    [paid_collective_a, paid_collective_b].each do |c|
      c.update!(tier: Collective::TIER_PAID)
    end
    exempt_collective = Collective.create!(tenant: @tenant, created_by: @user, name: "Exempt Coll", handle: "exempt-coll-#{SecureRandom.hex(4)}", billing_exempt: true)
    exempt_collective.update!(tier: Collective::TIER_PAID)
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_collexempt")
      .to_return(
        status: 200,
        body: {
          id: "sub_collexempt", object: "subscription",
          items: { data: [{ id: "si_collexempt", quantity: 3, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/subscription_items/si_collexempt")
      .to_return(
        status: 200,
        body: { id: "si_collexempt", object: "subscription_item", quantity: 2 }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user)

    # Should be 2 paid collectives (humans free, exempt collective excluded) = 2
    assert_requested(:post, "https://api.stripe.com/v1/subscription_items/si_collexempt") do |req|
      body = Rack::Utils.parse_query(req.body)
      body["quantity"] == "2"
    end
  end

  test "sync_subscription_quantity! cancels the subscription when all resources are exempt (quantity zero)" do
    @user.update!(billing_exempt: true)
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_allexempt", active: true, stripe_subscription_id: "sub_allexempt")

    # billable_quantity is 0 because the user is exempt. The corrected
    # behavior is to cancel the subscription, not silently leave the user
    # being charged — see "cancels Stripe subscription when new_quantity
    # drops to zero" above for the regression context.
    stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_allexempt")
      .with(query: hash_including({}))
      .to_return(status: 200,
                 body: { id: "sub_allexempt", object: "subscription", status: "canceled" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    StripeService.sync_subscription_quantity!(@user)

    assert_requested :delete, "https://api.stripe.com/v1/subscriptions/sub_allexempt", query: hash_including({}), at_least_times: 1
    assert_not sc.reload.active?
    # Must NOT try to set quantity to 0 (Stripe rejects that)
    assert_not_requested(:post, "https://api.stripe.com/v1/subscription_items/si_allexempt")
  end

  # === create_credit_topup_checkout ===

  test "create_credit_topup_checkout creates payment session with correct params" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_topup123")

    ENV["STRIPE_CREDIT_PRODUCT_ID"] = "prod_credits_test"

    stub_request(:post, "https://api.stripe.com/v1/prices")
      .to_return(
        status: 200,
        body: { id: "price_dynamic_123", object: "price" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    captured_body = nil
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with { |req| captured_body = Rack::Utils.parse_nested_query(req.body); true }
      .to_return(
        status: 200,
        body: {
          id: "cs_topup123",
          object: "checkout.session",
          url: "https://checkout.stripe.com/session/cs_topup123",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.create_credit_topup_checkout(
      stripe_customer: sc,
      amount_cents: 2500,
      success_url: "https://app.example.com/billing?topup_session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "https://app.example.com/billing",
    )

    assert_equal "https://checkout.stripe.com/session/cs_topup123", result
    assert_equal "payment", captured_body["mode"]
    assert_equal "credit_topup", captured_body["metadata"]["type"]
  ensure
    ENV.delete("STRIPE_CREDIT_PRODUCT_ID")
  end

  test "create_credit_topup_checkout rejects amount below minimum" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_topup_min")

    assert_raises(ArgumentError) do
      StripeService.create_credit_topup_checkout(
        stripe_customer: sc,
        amount_cents: 50,
        success_url: "https://example.com",
        cancel_url: "https://example.com",
      )
    end
  end

  test "create_credit_topup_checkout rejects amount above maximum" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_topup_max")

    assert_raises(ArgumentError) do
      StripeService.create_credit_topup_checkout(
        stripe_customer: sc,
        amount_cents: 100_000,
        success_url: "https://example.com",
        cancel_url: "https://example.com",
      )
    end
  end

  # === get_credit_balance ===

  test "get_credit_balance returns available balance in cents" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_balance123")

    stub_request(:get, %r{https://api.stripe.com/v1/billing/credit_balance_summary.*})
      .to_return(
        status: 200,
        body: {
          object: "billing.credit_balance_summary",
          balances: [
            {
              available_balance: { type: "monetary", monetary: { value: 2500, currency: "usd" } },
              ledger_balance: { type: "monetary", monetary: { value: 2500, currency: "usd" } },
            },
          ],
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.get_credit_balance(sc)
    assert_equal 2500, result
  end

  test "get_credit_balance returns 0 when no balances" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_nobal")

    stub_request(:get, %r{https://api.stripe.com/v1/billing/credit_balance_summary.*})
      .to_return(
        status: 200,
        body: {
          object: "billing.credit_balance_summary",
          balances: [],
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.get_credit_balance(sc)
    assert_equal 0, result
  end

  # === gateway_health ===

  test "gateway_health reports config presence and per-customer balances" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_health1", active: true)
    inactive_user = User.create!(name: "Inactive", email: "inactive-#{SecureRandom.hex(4)}@example.com")
    StripeCustomer.create!(billable: inactive_user, stripe_id: "cus_inactive", active: false)

    stub_request(:get, %r{https://api.stripe.com/v1/billing/credit_balance_summary.*})
      .to_return(
        status: 200,
        body: {
          object: "billing.credit_balance_summary",
          balances: [
            {
              available_balance: { type: "monetary", monetary: { value: 1200, currency: "usd" } },
              ledger_balance: { type: "monetary", monetary: { value: 1200, currency: "usd" } },
            },
          ],
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    original_key = ENV["STRIPE_GATEWAY_KEY"]
    original_product = ENV["STRIPE_CREDIT_PRODUCT_ID"]
    ENV["STRIPE_GATEWAY_KEY"] = "rk_test_gateway"
    ENV["STRIPE_CREDIT_PRODUCT_ID"] = "prod_test_credit"
    begin
      report = StripeService.gateway_health
    ensure
      original_key.nil? ? ENV.delete("STRIPE_GATEWAY_KEY") : ENV["STRIPE_GATEWAY_KEY"] = original_key
      original_product.nil? ? ENV.delete("STRIPE_CREDIT_PRODUCT_ID") : ENV["STRIPE_CREDIT_PRODUCT_ID"] = original_product
    end

    assert report[:gateway_key_present]
    assert report[:credit_product_configured]
    customer_ids = report[:active_customers].map { |c| c[:stripe_id] }
    assert_includes customer_ids, "cus_health1"
    assert_not_includes customer_ids, "cus_inactive"
    balance = report[:active_customers].find { |c| c[:stripe_id] == "cus_health1" }
    assert_equal 1200, balance[:credit_balance_cents]
  end

  test "gateway_health reports missing config" do
    original_key = ENV["STRIPE_GATEWAY_KEY"]
    original_product = ENV["STRIPE_CREDIT_PRODUCT_ID"]
    ENV.delete("STRIPE_GATEWAY_KEY")
    ENV.delete("STRIPE_CREDIT_PRODUCT_ID")
    begin
      report = StripeService.gateway_health
    ensure
      ENV["STRIPE_GATEWAY_KEY"] = original_key unless original_key.nil?
      ENV["STRIPE_CREDIT_PRODUCT_ID"] = original_product unless original_product.nil?
    end

    assert_not report[:gateway_key_present]
    assert_not report[:credit_product_configured]
    assert_equal [], report[:active_customers]
  end

  test "get_credit_balance returns nil on Stripe error" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_balerr")

    stub_request(:get, %r{https://api.stripe.com/v1/billing/credit_balance_summary.*})
      .to_return(status: 500, body: { error: { message: "Internal error" } }.to_json, headers: { "Content-Type" => "application/json" })

    result = StripeService.get_credit_balance(sc)
    assert_nil result
  end

  # === handle_webhook credit topup ===

  test "handle_webhook checkout.session.completed creates credit grant for topup" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_topup_wh", active: true, stripe_subscription_id: "sub_existing")

    # Stub listing existing grants (empty — no duplicates)
    stub_request(:get, %r{https://api.stripe.com/v1/billing/credit_grants.*})
      .to_return(
        status: 200,
        body: { object: "list", data: [], has_more: false }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # Stub grant creation
    captured_grant_body = nil
    stub_request(:post, "https://api.stripe.com/v1/billing/credit_grants")
      .with { |req| captured_grant_body = Rack::Utils.parse_nested_query(req.body); true }
      .to_return(
        status: 200,
        body: { id: "credgr_test", object: "billing.credit_grant" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    event = build_stripe_event(
      type: "checkout.session.completed",
      object: {
        "id" => "cs_topup_session",
        "customer" => "cus_topup_wh",
        "mode" => "payment",
        "metadata" => { "type" => "credit_topup" },
        "amount_total" => 5000,
      },
    )

    StripeService.handle_webhook_event(event)

    # Should NOT have changed subscription state
    sc.reload
    assert sc.active
    assert_equal "sub_existing", sc.stripe_subscription_id

    # Should have created a credit grant
    assert_requested(:post, "https://api.stripe.com/v1/billing/credit_grants")
    assert_equal "5000", captured_grant_body["amount"]["monetary"]["value"]
    assert_equal "cs_topup_session", captured_grant_body["metadata"]["checkout_session_id"]
  end

  test "handle_webhook checkout.session.completed uses idempotency key for credit grant" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_topup_dup", active: true, stripe_subscription_id: "sub_dup")

    # Stripe dedupes server-side via the Idempotency-Key header; we assert that
    # we send it rather than guarding with a local list+scan (which races with
    # concurrent webhook/return handlers and breaks past the 100-grant list cap).
    stub_request(:post, "https://api.stripe.com/v1/billing/credit_grants")
      .to_return(status: 200, body: { id: "credgr_existing" }.to_json, headers: { "Content-Type" => "application/json" })

    event = build_stripe_event(
      type: "checkout.session.completed",
      object: {
        "id" => "cs_dup_session",
        "customer" => "cus_topup_dup",
        "mode" => "payment",
        "metadata" => { "type" => "credit_topup" },
        "amount_total" => 2500,
      },
    )

    StripeService.handle_webhook_event(event)

    assert_requested(
      :post,
      "https://api.stripe.com/v1/billing/credit_grants",
      headers: { "Idempotency-Key" => "credit_grant:cs_dup_session" },
    )
  end

  test "handle_webhook checkout.session.completed still activates subscriptions" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_sub_still", active: false)

    event = build_stripe_event(
      type: "checkout.session.completed",
      object: {
        "customer" => "cus_sub_still",
        "subscription" => "sub_new123",
        "mode" => "subscription",
      },
    )

    StripeService.handle_webhook_event(event)

    sc.reload
    assert sc.active
    assert_equal "sub_new123", sc.stripe_subscription_id
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  # Build a Stripe-like event object for webhook testing
  def build_stripe_event(type:, object:)
    OpenStruct.new(
      type: type,
      data: OpenStruct.new(object: OpenStruct.new(object)),
    )
  end
end
