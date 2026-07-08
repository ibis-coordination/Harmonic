# typed: false

require "test_helper"

class BillingGateTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"

    @tenant.set_feature_flag!("internal_ai_agents", true)
    @tenant.set_feature_flag!("external_ai_agents", true)
    enable_stripe_billing_flag!(@tenant)
    # Make @collective paid_tier so @user has a billable resource and the
    # billing gate has something to fire on. Under the free/paid tier model,
    # a fresh non-main collective alone is not billable.
    make_collective_paid_tier!(@collective)
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
    get "/settings"

    assert_response :success
  end

  # === Humans-free model ===

  test "fresh human user with no billable resources is NOT redirected to /billing" do
    # Humans are free under the current model. Only AI agents and additional
    # collectives are billed. A fresh user with neither should be allowed in.
    fresh_tenant = create_tenant(subdomain: "fresh-gate-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "fresh-gate-#{SecureRandom.hex(4)}@example.com", name: "Fresh Gate")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)

    sign_in_as(fresh_user, tenant: fresh_tenant)
    get "/"

    assert_response :success
    assert_no_match %r{/billing}, response.body[0..1000] || "",
                    "fresh humans without agents or extra collectives should not be billing-gated"
  end

  test "billing_exempt human with an API token is NOT redirected to /billing" do
    fresh_tenant = create_tenant(subdomain: "exempt-gate-#{SecureRandom.hex(4)}")
    enable_stripe_billing_flag!(fresh_tenant)
    fresh_user = create_user(email: "exempt-gate-#{SecureRandom.hex(4)}@example.com", name: "Exempt Gate")
    fresh_tenant.add_user!(fresh_user)
    fresh_tenant.create_main_collective!(created_by: fresh_user)
    ApiToken.create!(
      user: fresh_user,
      tenant: fresh_tenant,
      name: "Exempt Gate Token",
      scopes: ["read:all"],
      expires_at: 1.year.from_now,
    )
    fresh_user.update!(billing_exempt: true)

    sign_in_as(fresh_user, tenant: fresh_tenant)
    get "/"

    assert_response :success
  end

  # === return_to preservation ===

  test "billing gate saves request path to session so user is resumed after checkout" do
    sign_in_as(@user, tenant: @tenant)

    # Simulate a user arriving at an invite URL mid-flow when billing gate fires
    get "/collectives/#{@collective.handle}/join?code=abc123"

    assert_response :redirect
    assert_match %r{/billing}, response.location
    assert_equal "/collectives/#{@collective.handle}/join?code=abc123",
                 session[:billing_return_to],
                 "expected billing gate to stash request.fullpath so BillingController can resume the user there after checkout"
  end

  test "billing gate ignores JSON/XHR requests for return_to (avoids clobbering by background polls)" do
    # Regression: the unread_count notification poll (and any other background
    # JSON fetch) fires the gate too. Without filtering, whichever request
    # finishes last wins session[:billing_return_to] — typically the JSON
    # endpoint, leaving the user redirected to /notifications/unread_count
    # after Stripe checkout.
    sign_in_as(@user, tenant: @tenant)

    # First, a real navigation that we want to resume to:
    get "/collectives/#{@collective.handle}/join?code=abc123"
    assert_equal "/collectives/#{@collective.handle}/join?code=abc123",
                 session[:billing_return_to]

    # Then, simulate the bell-icon JSON poll firing
    get "/notifications/unread_count", as: :json

    assert_equal "/collectives/#{@collective.handle}/join?code=abc123",
                 session[:billing_return_to],
                 "expected JSON poll to NOT overwrite the user's actual destination"
  end

  test "billing gate sets a flash notice explaining why the user was redirected" do
    sign_in_as(@user, tenant: @tenant)

    get "/collectives/#{@collective.handle}/join?code=abc123"

    assert_response :redirect
    assert flash[:notice].present?,
           "expected a flash notice explaining the bounce to /billing"
    assert_match(/billing|set up payment|continue/i, flash[:notice].to_s,
                 "expected the notice to reference billing setup as the next step")
  end

  test "billing gate does NOT set a flash for JSON/XHR requests" do
    # No human ever sees that flash, and it'd clobber the real one.
    sign_in_as(@user, tenant: @tenant)

    get "/notifications/unread_count", as: :json

    assert_nil flash[:notice]
  end

  test "billing gate does not stomp the return_to with /billing itself" do
    # The billing controller is exempt — gate shouldn't fire when already on /billing.
    sign_in_as(@user, tenant: @tenant)

    get "/billing"

    assert_response :success
    assert_nil session[:billing_return_to],
               "expected no return_to to be set when the gate is exempt"
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

  def make_collective_paid_tier!(collective)
    collective.update!(tier: Collective::TIER_PAID)
  end
end
