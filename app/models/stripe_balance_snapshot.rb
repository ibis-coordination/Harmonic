# typed: true
# frozen_string_literal: true

# A cached read of a Stripe customer's prepaid credit balance, used by
# LLMGateway::BalanceGate: effective balance = this snapshot minus the usage
# ledger's spend since fetched_at. Refreshed on TTL expiry, on a payer's
# first zero-crossing (verify before rejecting), and invalidated on top-up.
#
# Not tenant-scoped (no tenant_id column, like StripeCustomer): a customer's
# balance is one pot regardless of which tenant their agents spend in.
class StripeBalanceSnapshot < ApplicationRecord
  self.implicit_order_column = "created_at"

  validates :stripe_customer_id, presence: true, uniqueness: true
  validates :balance_cents, presence: true
  validates :fetched_at, presence: true
end
