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

      # Recover stuck pending resources: if billing is active, clear pending flags
      # and backfill stripe_customer_id for any agents missing it.
      pending_agents = user.ai_agents.where(pending_billing_setup: true)
      if pending_agents.exists?
        pending_agents.where(stripe_customer_id: nil).update_all(stripe_customer_id: sc.id)
        pending_agents.update_all(pending_billing_setup: false)
        Rails.logger.info("[BillingReconciliationJob] Recovered #{pending_agents.count} pending agents for user #{user.id}")
      end

      pending_collectives = Collective.for_user_across_tenants(user).where(pending_billing_setup: true)
      if pending_collectives.exists?
        pending_collectives.update_all(pending_billing_setup: false)
        Rails.logger.info("[BillingReconciliationJob] Recovered #{pending_collectives.count} pending collectives for user #{user.id}")
      end

      StripeService.sync_subscription_quantity!(user)
    rescue => e
      Rails.logger.error("[BillingReconciliationJob] Failed for user #{user&.id}: #{e.message}")
    end
  end
end
