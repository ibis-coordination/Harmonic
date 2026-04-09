# typed: true
# frozen_string_literal: true

# Safety net job that reconciles Stripe subscription quantities with actual
# active agent counts. Catches drift from failed Stripe API calls during
# agent lifecycle events. Should run daily.
class BillingReconciliationJob < SystemJob
  extend T::Sig

  queue_as :low_priority

  sig { void }
  def perform
    StripeCustomer.where(active: true, billable_type: "User")
      .where.not(stripe_subscription_id: nil)
      .find_each do |sc|
      user = sc.billable
      next unless user
      next if user.billing_exempt?

      tenant = user.tenant_users.first&.tenant
      next unless tenant&.feature_enabled?("stripe_billing")

      StripeService.sync_subscription_quantity!(user, tenant)
    rescue => e
      Rails.logger.error("[BillingReconciliationJob] Failed for user #{user&.id}: #{e.message}")
    end
  end
end
