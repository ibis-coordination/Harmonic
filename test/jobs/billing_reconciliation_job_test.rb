# typed: false

require "test_helper"
require "webmock/minitest"

class BillingReconciliationJobTest < ActiveJob::TestCase
  setup do
    @original_stripe_key = Stripe.api_key
    Stripe.api_key = "sk_test_fake"
  end

  teardown do
    Stripe.api_key = @original_stripe_key
  end

  test "reconciles subscription quantities for active customers" do
    tenant, collective, user = create_tenant_collective_user
    enable_stripe_billing_flag!(tenant)
    sc = StripeCustomer.create!(billable: user, stripe_id: "cus_recon", active: true, stripe_subscription_id: "sub_recon")

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_recon")
      .to_return(
        status: 200,
        body: {
          id: "sub_recon", object: "subscription",
          items: { data: [{ id: "si_recon", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # No agents, quantity already 1 — should be no-op (no SubscriptionItem update)
    BillingReconciliationJob.perform_now

    assert_not_requested(:post, "https://api.stripe.com/v1/subscription_items/si_recon")
  end

  test "skips billing_exempt users" do
    tenant, collective, user = create_tenant_collective_user
    enable_stripe_billing_flag!(tenant)
    user.update!(billing_exempt: true)
    StripeCustomer.create!(billable: user, stripe_id: "cus_exempt_recon", active: true, stripe_subscription_id: "sub_exempt_recon")

    # No Stripe calls should be made
    BillingReconciliationJob.perform_now

    assert_not_requested(:get, /api\.stripe\.com\/v1\/subscriptions/)
  end

  test "continues processing when one user fails" do
    tenant, collective, user1 = create_tenant_collective_user
    enable_stripe_billing_flag!(tenant)
    StripeCustomer.create!(billable: user1, stripe_id: "cus_fail_recon", active: true, stripe_subscription_id: "sub_fail_recon")

    user2 = create_user(email: "recon2-#{SecureRandom.hex(4)}@example.com", name: "Recon User 2 #{SecureRandom.hex(4)}")
    tenant.add_user!(user2)
    StripeCustomer.create!(billable: user2, stripe_id: "cus_ok_recon", active: true, stripe_subscription_id: "sub_ok_recon")

    # First user fails
    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_fail_recon")
      .to_return(status: 500, body: { error: { message: "Error" } }.to_json)

    # Second user succeeds (quantity matches, no update needed)
    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_ok_recon")
      .to_return(
        status: 200,
        body: {
          id: "sub_ok_recon", object: "subscription",
          items: { data: [{ id: "si_ok_recon", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # Should not raise — processes both users
    assert_nothing_raised do
      BillingReconciliationJob.perform_now
    end

    # Second user's subscription was checked
    assert_requested(:get, "https://api.stripe.com/v1/subscriptions/sub_ok_recon")
  end

  private

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end
end
