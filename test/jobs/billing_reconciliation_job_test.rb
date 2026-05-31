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
    tenant.update!(main_collective_id: collective.id)
    enable_stripe_billing_flag!(tenant)
    StripeCustomer.create!(billable: user, stripe_id: "cus_recon", active: true, stripe_subscription_id: "sub_recon")
    # One billable agent → user.billable_quantity == 1, matches the stubbed
    # Stripe quantity below. (Without the agent, billable_quantity would be
    # 0 and reconciliation would CANCEL the subscription rather than no-op.
    # See "cancels subscription when billable_quantity drops to zero" below.)
    agent = create_ai_agent(parent: user, name: "Recon Agent #{SecureRandom.hex(4)}")
    tenant.add_user!(agent)

    stub_request(:get, "https://api.stripe.com/v1/subscriptions/sub_recon")
      .to_return(
        status: 200,
        body: {
          id: "sub_recon", object: "subscription", status: "active",
          items: { data: [{ id: "si_recon", quantity: 1, price: { id: "price_test" } }] },
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    # Quantity matches → should be no-op (no SubscriptionItem update)
    BillingReconciliationJob.perform_now

    assert_not_requested(:post, "https://api.stripe.com/v1/subscription_items/si_recon")
  end

  test "cancels subscription for billing_exempt users (their billable_quantity is zero)" do
    tenant, collective, user = create_tenant_collective_user
    tenant.update!(main_collective_id: collective.id)
    enable_stripe_billing_flag!(tenant)
    user.update!(billing_exempt: true)
    sc = StripeCustomer.create!(billable: user, stripe_id: "cus_exempt_recon", active: true, stripe_subscription_id: "sub_exempt_recon")
    stub_request(:delete, "https://api.stripe.com/v1/subscriptions/sub_exempt_recon")
      .to_return(status: 200,
                 body: { id: "sub_exempt_recon", object: "subscription", status: "canceled" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    BillingReconciliationJob.perform_now

    # When the daily job sees an exempt user with billable_quantity == 0
    # holding an active Stripe subscription, it cancels the subscription —
    # rather than silently leaving them being charged. (Old behavior was a
    # no-op; the regression is covered by the matching service-level test.)
    assert_requested :delete, "https://api.stripe.com/v1/subscriptions/sub_exempt_recon", at_least_times: 1
    assert_not sc.reload.active?
  end

  test "continues processing when one user fails" do
    tenant, collective, user1 = create_tenant_collective_user
    tenant.update!(main_collective_id: collective.id)
    enable_stripe_billing_flag!(tenant)
    StripeCustomer.create!(billable: user1, stripe_id: "cus_fail_recon", active: true, stripe_subscription_id: "sub_fail_recon")
    # Each user needs at least one billable resource so sync_subscription_quantity!
    # actually issues a Stripe request (it short-circuits when billable_quantity == 0).
    user1_agent = create_ai_agent(parent: user1, name: "Recon Agent 1 #{SecureRandom.hex(4)}")
    tenant.add_user!(user1_agent)

    user2 = create_user(email: "recon2-#{SecureRandom.hex(4)}@example.com", name: "Recon User 2 #{SecureRandom.hex(4)}")
    tenant.add_user!(user2)
    StripeCustomer.create!(billable: user2, stripe_id: "cus_ok_recon", active: true, stripe_subscription_id: "sub_ok_recon")
    user2_agent = create_ai_agent(parent: user2, name: "Recon Agent 2 #{SecureRandom.hex(4)}")
    tenant.add_user!(user2_agent)

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
