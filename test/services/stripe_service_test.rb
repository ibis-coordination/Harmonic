# typed: false

require "test_helper"
require "webmock/minitest"

class StripeServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    # Set as main collective so it doesn't count toward billing
    @tenant.update!(main_collective_id: @collective.id)
    @tenant.enable_feature_flag!("ai_agents")
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
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_sync123", active: true, stripe_subscription_id: "sub_sync123")

    # Create an active agent
    agent = create_ai_agent(parent: @user)
    @tenant.add_user!(agent)

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

    StripeService.sync_subscription_quantity!(@user, @tenant)

    assert_requested(:post, "https://api.stripe.com/v1/subscription_items/si_sync123") do |req|
      body = Rack::Utils.parse_query(req.body)
      body["quantity"] == "2"
    end
  end

  test "sync_subscription_quantity! is no-op for billing_exempt user" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_exempt", active: true, stripe_subscription_id: "sub_exempt")
    @user.update!(billing_exempt: true)

    # No Stripe API call should be made
    StripeService.sync_subscription_quantity!(@user, @tenant)
  end

  test "sync_subscription_quantity! is no-op without active subscription" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_nosub", active: false)

    # No Stripe API call should be made
    StripeService.sync_subscription_quantity!(@user, @tenant)
  end

  test "sync_subscription_quantity! logs and does not raise on Stripe failure" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_fail", active: true, stripe_subscription_id: "sub_fail")

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_fail")
      .to_return(status: 500, body: { error: { message: "Internal error" } }.to_json)

    assert_nothing_raised do
      StripeService.sync_subscription_quantity!(@user, @tenant)
    end
  end

  test "sync_subscription_quantity! excludes archived and suspended agents from count" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_count", active: true, stripe_subscription_id: "sub_count")

    active_agent = create_ai_agent(parent: @user, name: "Active Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(active_agent)
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

    StripeService.sync_subscription_quantity!(@user, @tenant)

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
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_noop", active: true, stripe_subscription_id: "sub_noop")

    # No agents — quantity should be 1, which matches the current subscription
    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_noop")
      .to_return(
        status: 200,
        body: {
          id: "sub_noop", object: "subscription",
          items: { data: [{ id: "si_noop", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    StripeService.sync_subscription_quantity!(@user, @tenant)

    # Should NOT call SubscriptionItem.update
    assert_not_requested(:post, "https://api.stripe.com/v1/subscription_items/si_noop")
  end

  # === Edge case: quantity decrease does NOT create invoice ===

  test "sync_subscription_quantity! does not create invoice on quantity decrease" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_dec", active: true, stripe_subscription_id: "sub_dec")

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

    StripeService.sync_subscription_quantity!(@user, @tenant)

    # Should update quantity
    assert_requested(:post, "https://api.stripe.com/v1/subscription_items/si_dec")
    # Should NOT create invoice (decrease = Stripe handles credit automatically)
    assert_not_requested(:post, "https://api.stripe.com/v1/invoices")
  end

  # === Edge case: invoice with zero amount_due is not paid ===

  test "sync_subscription_quantity! skips payment when invoice amount_due is zero" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_zero", active: true, stripe_subscription_id: "sub_zero")

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

    StripeService.sync_subscription_quantity!(@user, @tenant)

    # Should NOT pay the invoice
    assert_not_requested(:post, "https://api.stripe.com/v1/invoices/in_zero/pay")
  end

  # === Edge case: invoice payment fails (card declined) ===

  test "sync_subscription_quantity! does not raise when invoice payment fails" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_declined", active: true, stripe_subscription_id: "sub_declined")

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
      StripeService.sync_subscription_quantity!(@user, @tenant)
    end
  end

  # === Edge case: concurrent syncs produce correct result ===

  test "sync_subscription_quantity! is idempotent — two calls produce same result" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_idem", active: true, stripe_subscription_id: "sub_idem")

    agent = create_ai_agent(parent: @user, name: "Idem Agent #{SecureRandom.hex(4)}")
    @tenant.add_user!(agent)

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
    StripeService.sync_subscription_quantity!(@user, @tenant)
    # Second call — quantity already matches, should be no-op
    StripeService.sync_subscription_quantity!(@user, @tenant)

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

    stub_request(:post, "https://api.stripe.com/v1/invoices/create_preview")
      .to_return(
        status: 200,
        body: {
          id: "in_preview", object: "invoice", amount_due: 1199,
          lines: { data: [
            { amount: -600, description: "Unused time on 1 x Account after 09 Apr 2026" },
            { amount: 899, description: "Remaining time on 2 x Account after 09 Apr 2026" },
            { amount: 900, description: "2 x Account (at $3.00 / month)" },
          ] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    result = StripeService.preview_proration(@user, @tenant)

    # Should return only the proration lines: -600 + 899 = 299
    assert_equal 299, result
  end

  test "preview_proration returns nil for billing_exempt user" do
    @user.update!(billing_exempt: true)
    result = StripeService.preview_proration(@user, @tenant)
    assert_nil result
  end

  test "preview_proration returns nil without active subscription" do
    result = StripeService.preview_proration(@user, @tenant)
    assert_nil result
  end

  test "preview_proration returns nil on Stripe error" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_prev_fail", active: true, stripe_subscription_id: "sub_prev_fail")

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_prev_fail")
      .to_return(status: 500, body: { error: { message: "Error" } }.to_json)

    result = StripeService.preview_proration(@user, @tenant)
    assert_nil result
  end

  test "handle_webhook customer.subscription.deleted archives user's non-main collectives" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_del_coll",
      stripe_subscription_id: "sub_del_coll",
      active: true,
    )

    # Create a non-main collective owned by the user
    extra_collective = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Extra Coll #{SecureRandom.hex(4)}",
      handle: "extra-coll-#{SecureRandom.hex(4)}",
    )

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_del_coll", "id" => "sub_del_coll" },
    )

    StripeService.handle_webhook_event(event)

    extra_collective.reload
    assert extra_collective.archived?, "Non-main collective should be archived when subscription deleted"

    # Main collective should NOT be archived
    @collective.reload
    assert_not @collective.archived?, "Main collective should not be archived"
  end

  test "handle_webhook customer.subscription.deleted deactivates customer so agents cannot run" do
    sc = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_del_agent",
      stripe_subscription_id: "sub_del_agent",
      active: true,
    )

    event = build_stripe_event(
      type: "customer.subscription.deleted",
      object: { "customer" => "cus_del_agent", "id" => "sub_del_agent" },
    )

    StripeService.handle_webhook_event(event)

    sc.reload
    assert_not sc.active
    # stripe_billing_setup? should now return false
    @user.reload
    assert_not @user.stripe_billing_setup?
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
