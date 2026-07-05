# typed: false
class AddPricingPlanSubscriptionToStripeCustomers < ActiveRecord::Migration[7.2]
  def change
    add_column :stripe_customers, :pricing_plan_subscription_id, :string
  end
end
