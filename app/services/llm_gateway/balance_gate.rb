# typed: true
# frozen_string_literal: true

module LLMGateway
  # The self-owned zero-balance gate: decides per call whether a payer's
  # prepaid balance can absorb more spend, without a live Stripe call on the
  # hot path. Effective balance = cached snapshot minus the usage ledger's
  # estimated spend since the snapshot; every refresh re-zeros that local
  # delta, so estimate drift never accumulates.
  #
  # Stripe is consulted only when a snapshot is missing or older than the
  # TTL, and once more (throttled) when a payer first crosses zero — a stale
  # cache must never refuse a customer who just topped up. On Stripe failure
  # the last snapshot stands (stale beats refusing funded customers); a payer
  # with no snapshot at all fails closed.
  class BalanceGate
    extend T::Sig

    sig { returns(Integer) }
    def self.ttl_seconds
      ENV.fetch("GATEWAY_BALANCE_SNAPSHOT_TTL_SECONDS", "600").to_i
    end

    # Headroom above zero to absorb in-flight calls whose usage hasn't
    # landed in the ledger yet.
    sig { returns(Integer) }
    def self.buffer_cents
      ENV.fetch("GATEWAY_BALANCE_BUFFER_CENTS", "25").to_i
    end

    # A snapshot at most this old is trusted on a zero-crossing; anything
    # older gets one verifying refetch before the payer is refused.
    VERIFY_THROTTLE_SECONDS = 30

    sig { params(stripe_customer_id: String).returns(T::Boolean) }
    def self.funded?(stripe_customer_id)
      snapshot = fresh_snapshot(stripe_customer_id)
      return false if snapshot.nil?
      return true if effective_balance_cents(snapshot) > buffer_cents

      # Verify before rejecting: one fresh look, unless we just took one.
      if snapshot.fetched_at < VERIFY_THROTTLE_SECONDS.seconds.ago
        snapshot = refresh!(stripe_customer_id) || snapshot
      end
      effective_balance_cents(snapshot) > buffer_cents
    end

    sig { params(stripe_customer_id: String).void }
    def self.invalidate!(stripe_customer_id)
      StripeBalanceSnapshot.where(stripe_customer_id: stripe_customer_id).delete_all
    end

    sig { params(stripe_customer_id: String).returns(T.nilable(StripeBalanceSnapshot)) }
    def self.fresh_snapshot(stripe_customer_id)
      snapshot = StripeBalanceSnapshot.find_by(stripe_customer_id: stripe_customer_id)
      return snapshot if snapshot && snapshot.fetched_at > ttl_seconds.seconds.ago

      refresh!(stripe_customer_id) || snapshot
    end

    sig { params(stripe_customer_id: String).returns(T.nilable(StripeBalanceSnapshot)) }
    def self.refresh!(stripe_customer_id)
      customer = StripeCustomer.find_by(stripe_id: stripe_customer_id)
      return nil if customer.nil?

      balance = StripeService.get_credit_balance(customer)
      if balance.nil?
        Rails.logger.warn("[LLMGateway::BalanceGate] Balance fetch failed for #{stripe_customer_id}; keeping prior snapshot")
        return nil
      end

      snapshot = StripeBalanceSnapshot.find_or_initialize_by(stripe_customer_id: stripe_customer_id)
      snapshot.update!(balance_cents: balance, fetched_at: Time.current)
      snapshot
    rescue ActiveRecord::RecordNotUnique
      # Two concurrent first-refreshes raced on the unique index; the other
      # writer's row is equally fresh.
      StripeBalanceSnapshot.find_by(stripe_customer_id: stripe_customer_id)
    end

    sig { params(snapshot: StripeBalanceSnapshot).returns(BigDecimal) }
    def self.effective_balance_cents(snapshot)
      # Anchored on completed_at, not occurred_at: a call opened before the
      # snapshot but costed after it is in neither the Stripe balance nor an
      # occurred_at-anchored delta.
      spend = LLMUsageRecord.where(payer_stripe_customer_id: snapshot.stripe_customer_id)
                            .where(completed_at: snapshot.fetched_at..)
                            .sum(:estimated_cost_cents)
      BigDecimal(snapshot.balance_cents) - spend
    end
  end
end
