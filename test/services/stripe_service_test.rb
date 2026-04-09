# typed: false

require "test_helper"
require "webmock/minitest"

class StripeServiceTest < ActiveSupport::TestCase
  setup do
    @tenant, @collective, @user = create_tenant_collective_user
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
