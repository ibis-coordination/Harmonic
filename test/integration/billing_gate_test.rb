# typed: false

require "test_helper"

class BillingGateTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    @tenant.set_feature_flag!("ai_agents", true)
    enable_stripe_billing_flag!(@tenant)
  end

  # === Gate enforced ===

  test "authenticated human user without billing is redirected to /billing" do
    # User has no StripeCustomer → billing not set up
    sign_in_as(@user, tenant: @tenant)
    get "/"

    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  test "authenticated human user with active billing can access app normally" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_gate_active", active: true)

    sign_in_as(@user, tenant: @tenant)
    get "/"

    assert_response :success
  end

  test "authenticated user with inactive billing is redirected to /billing" do
    StripeCustomer.create!(billable: @user, stripe_id: "cus_gate_inactive", active: false)

    sign_in_as(@user, tenant: @tenant)
    get "/"

    assert_response :redirect
    assert_match %r{/billing}, response.location
  end

  # === Exemptions ===

  test "billing controller is exempt from billing gate redirect" do
    sign_in_as(@user, tenant: @tenant)
    get "/billing"

    assert_response :success
  end

  test "login routes are exempt from billing gate" do
    get "/login"

    # Should not redirect to /billing — should either render login or redirect to auth
    assert_not_equal "/billing", response.location&.split("?")&.first
  end

  test "webhook endpoint is exempt from billing gate" do
    post "/stripe/webhooks",
      params: "{}",
      headers: { "Content-Type" => "application/json", "Stripe-Signature" => "t=123,v1=abc" }

    # Should not redirect to /billing (will fail auth, but not with billing redirect)
    assert_not_equal 302, response.status
  end

  test "billing gate is not enforced when stripe_billing flag is off" do
    @tenant.disable_feature_flag!("stripe_billing")

    sign_in_as(@user, tenant: @tenant)
    get "/"

    assert_response :success
  end

  test "user settings page is exempt from billing gate" do
    sign_in_as(@user, tenant: @tenant)
    get "/u/#{@user.handle}/settings"

    assert_response :success
  end

  test "unauthenticated users are not affected by billing gate" do
    # Unauthenticated user should be redirected to login, not billing
    get "/"

    if response.redirect?
      assert_no_match %r{/billing}, response.location
    else
      assert_response :success
    end
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end
end
