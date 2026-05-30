# typed: true

# Builds Stripe Checkout sessions for user-initiated billing flows.
#
# The per-user "set up billing" flow lives in BillingController#setup; this
# service is the shared entry point used by both that flow and the new
# CollectivesController#upgrade flow. Collective upgrades stash the
# collective_id in session metadata so the checkout.session.completed
# webhook can confirm_upgrade! the right collective.
class StripeCheckoutService
  extend T::Sig

  sig do
    params(
      user: User,
      collective: Collective,
      success_url: String,
      cancel_url: String,
    ).returns(String)
  end
  def self.create_session_for_collective_upgrade!(user:, collective:, success_url:, cancel_url:)
    stripe_customer = StripeService.find_or_create_customer(user)

    # Include the to-be-upgraded collective in the quantity. Once the
    # webhook flips its tier to PAID, billable_quantity will already
    # match — no follow-up sync_subscription_quantity! call needed.
    quantity = user.billable_quantity + (collective.free_tier? ? 1 : 0)
    quantity = 1 if quantity < 1

    session = Stripe::Checkout::Session.create(
      customer: stripe_customer.stripe_id,
      mode: "subscription",
      line_items: [
        {
          price: ENV.fetch("STRIPE_PRICE_ID"),
          quantity: quantity,
        },
      ],
      success_url: success_url,
      cancel_url: cancel_url,
      metadata: { collective_id: collective.id },
    )

    T.must(session.url)
  end
end
