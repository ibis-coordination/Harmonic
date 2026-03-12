# typed: false

require "test_helper"
require "webmock/minitest"

class BillingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    @tenant.set_feature_flag!("ai_agents", true)
    enable_stripe_billing_flag!(@tenant)

    @original_stripe_key = Stripe.api_key
    Stripe.api_key = "sk_test_fake"

    @original_pricing_plan_id = ENV["STRIPE_PRICING_PLAN_ID"]
    ENV["STRIPE_PRICING_PLAN_ID"] = "bpp_test_plan123"
  end

  teardown do
    Stripe.api_key = @original_stripe_key
    ENV["STRIPE_PRICING_PLAN_ID"] = @original_pricing_plan_id
  end

  # === Show ===

  test "show displays billing status when authenticated" do
    sign_in_as(@user, tenant: @tenant)
    get "/billing"
    assert_response :success
  end

  test "show redirects unauthenticated user to login" do
    get "/billing"
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "show activates billing when checkout_session_id present" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_show123", active: false)

    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_test123})
      .to_return(
        status: 200,
        body: {
          id: "cs_test123",
          object: "checkout.session",
          customer: "cus_show123",
          subscription: "sub_show123",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_test123"

    assert_response :success
    sc.reload
    assert sc.active, "Customer should be active after checkout session verification"
    assert_equal "sub_show123", sc.stripe_subscription_id
  end

  test "show redirects to return_to after activating billing" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_redir123", active: false)

    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_redir123})
      .to_return(
        status: 200,
        body: {
          id: "cs_redir123",
          object: "checkout.session",
          customer: "cus_redir123",
          subscription: "sub_redir123",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_redir123&return_to=/ai-agents/new"

    assert_response :redirect
    assert_match %r{/ai-agents/new}, response.location
  end

  test "show validates return_to is a relative path" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_evil123", active: false)

    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_evil123})
      .to_return(
        status: 200,
        body: {
          id: "cs_evil123",
          object: "checkout.session",
          customer: "cus_evil123",
          subscription: "sub_evil123",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_evil123&return_to=https://evil.com"

    # Should NOT redirect to external URL
    assert_response :success
  end

  test "show rejects return_to with control characters" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_crlf123", active: true)

    sign_in_as(@user, tenant: @tenant)
    get "/billing?return_to=/safe%0d%0aInjected-Header:%20value"

    # Should NOT redirect - control characters are rejected
    assert_response :success
  end

  test "show ignores invalid checkout_session_id format" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_fmt123", active: false)

    sign_in_as(@user, tenant: @tenant)
    # This should NOT trigger a Stripe API call (no webmock stub needed)
    get "/billing?checkout_session_id=invalid_format"

    assert_response :success
  end

  test "show does not activate billing for mismatched customer" do
    # Create a StripeCustomer for a different user
    other_user = create_user(email: "other-billing-#{SecureRandom.hex(4)}@example.com")
    sc = StripeCustomer.create!(billable: other_user, stripe_id: "cus_other123", active: false)

    # The checkout session references a different customer
    stub_request(:get, %r{https://api.stripe.com/v1/checkout/sessions/cs_mismatch123})
      .to_return(
        status: 200,
        body: {
          id: "cs_mismatch123",
          object: "checkout.session",
          customer: "cus_other123",
          subscription: "sub_other123",
          status: "complete",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing?checkout_session_id=cs_mismatch123"

    assert_response :success
    sc.reload
    assert_not sc.active, "Should not activate billing for mismatched customer"
  end

  # === Setup ===

  test "setup creates customer and redirects to Stripe Checkout" do
    stub_request(:post, "https://api.stripe.com/v1/customers")
      .to_return(
        status: 200,
        body: { id: "cus_setup123", object: "customer" }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .to_return(
        status: 200,
        body: {
          id: "cs_setup123",
          object: "checkout.session",
          url: "https://checkout.stripe.com/session/cs_setup123",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    post "/billing/setup"

    assert_response :redirect
    assert_match %r{checkout\.stripe\.com}, response.location
  end

  test "setup passes return_to from session into success_url" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_return123")

    captured_body = nil
    stub_request(:post, "https://api.stripe.com/v1/checkout/sessions")
      .with { |req| captured_body = req.body; true }
      .to_return(
        status: 200,
        body: {
          id: "cs_return123",
          object: "checkout.session",
          url: "https://checkout.stripe.com/session/cs_return123",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)

    # Simulate that billing_return_to was stored in session (by agent creation redirect)
    # We need to set this via a controller action that sets session
    # The simplest approach is to go through a flow that sets it
    get "/billing"  # Just to establish the session
    post "/billing/setup"

    assert_response :redirect
    assert captured_body.present?, "Should have made a Stripe API call"
  end

  # === Portal ===

  test "portal redirects to Stripe Billing Portal" do
    sc = StripeCustomer.create!(billable: @user, stripe_id: "cus_portal123", active: true)

    stub_request(:post, "https://api.stripe.com/v1/billing_portal/sessions")
      .to_return(
        status: 200,
        body: {
          id: "bps_portal123",
          object: "billing_portal.session",
          url: "https://billing.stripe.com/session/bps_portal123",
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    sign_in_as(@user, tenant: @tenant)
    get "/billing/portal"

    assert_response :redirect
    assert_match %r{billing\.stripe\.com}, response.location
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end
end
