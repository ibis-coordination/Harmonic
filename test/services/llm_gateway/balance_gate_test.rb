# typed: false

require "test_helper"

module LLMGateway
  class BalanceGateTest < ActiveSupport::TestCase
    setup do
      @tenant, @collective, @user = create_tenant_collective_user
      @customer = StripeCustomer.create!(
        billable: @user, stripe_id: "cus_gate_test", active: true, pricing_plan_subscription_id: "bpps_gate"
      )
      @ai_agent = nil
    end

    def seed_snapshot!(balance_cents, fetched_at: Time.current, stripe_id: "cus_gate_test")
      StripeBalanceSnapshot.create!(stripe_customer_id: stripe_id, balance_cents: balance_cents, fetched_at: fetched_at)
    end

    def spend!(cents, occurred_at: Time.current, completed_at: occurred_at, stripe_id: "cus_gate_test")
      agent = @ai_agent ||= create_ai_agent(parent: @user)
      LLMUsageRecord.create!(
        selection_id: "sel_#{SecureRandom.uuid}",
        status: "completed",
        ai_agent_id: agent.id,
        payer_stripe_customer_id: stripe_id,
        origin_tenant_id: @tenant.id,
        estimated_cost_cents: cents,
        occurred_at: occurred_at,
        completed_at: completed_at,
      )
    end

    def no_stripe!(&block)
      StripeService.stub(:get_credit_balance, ->(_) { raise "must not fetch a live balance" }, &block)
    end

    test "funded when a fresh snapshot minus ledger spend clears the buffer" do
      seed_snapshot!(500)
      spend!(100)

      no_stripe! do
        assert BalanceGate.funded?("cus_gate_test")
      end
    end

    test "not funded when ledger spend drains the snapshot" do
      # Recently fetched (inside the verify throttle), so the zero-crossing
      # does not trigger another fetch — the drained view stands.
      seed_snapshot!(100, fetched_at: 5.seconds.ago)
      spend!(100)

      no_stripe! do
        assert_not BalanceGate.funded?("cus_gate_test")
      end
    end

    test "verify before rejecting: a zero-crossing forces one fresh snapshot" do
      seed_snapshot!(100, fetched_at: 5.minutes.ago)
      spend!(100)

      fetches = 0
      StripeService.stub :get_credit_balance, ->(_) { fetches += 1; 500 } do
        assert BalanceGate.funded?("cus_gate_test"), "the top-up visible in the fresh snapshot must rescue the check"
      end
      assert_equal 1, fetches
    end

    test "a stale snapshot refreshes on TTL expiry" do
      seed_snapshot!(0, fetched_at: 11.minutes.ago)

      StripeService.stub :get_credit_balance, ->(_) { 500 } do
        assert BalanceGate.funded?("cus_gate_test")
      end
      assert_equal 500, StripeBalanceSnapshot.find_by!(stripe_customer_id: "cus_gate_test").balance_cents
    end

    test "a Stripe failure keeps the stale snapshot rather than refusing service" do
      seed_snapshot!(500, fetched_at: 11.minutes.ago)

      StripeService.stub :get_credit_balance, ->(_) { nil } do
        assert BalanceGate.funded?("cus_gate_test")
      end
    end

    test "not funded when there is no snapshot and Stripe is unreachable" do
      StripeService.stub :get_credit_balance, ->(_) { nil } do
        assert_not BalanceGate.funded?("cus_gate_test")
      end
    end

    test "a first-ever check fetches and stores the snapshot" do
      StripeService.stub :get_credit_balance, ->(_) { 750 } do
        assert BalanceGate.funded?("cus_gate_test")
      end
      snapshot = StripeBalanceSnapshot.find_by!(stripe_customer_id: "cus_gate_test")
      assert_equal 750, snapshot.balance_cents
    end

    test "invalidate! forces the next check to refetch" do
      seed_snapshot!(0, fetched_at: 5.seconds.ago)

      BalanceGate.invalidate!("cus_gate_test")

      StripeService.stub :get_credit_balance, ->(_) { 500 } do
        assert BalanceGate.funded?("cus_gate_test")
      end
    end

    test "pending ledger rows without a cost do not count against the balance" do
      seed_snapshot!(100)
      agent = @ai_agent ||= create_ai_agent(parent: @user)
      LLMUsageRecord.create!(
        selection_id: "sel_#{SecureRandom.uuid}",
        status: "pending",
        ai_agent_id: agent.id,
        payer_stripe_customer_id: "cus_gate_test",
        origin_tenant_id: @tenant.id,
        occurred_at: Time.current,
      )

      no_stripe! do
        assert BalanceGate.funded?("cus_gate_test")
      end
    end

    test "spend completed after the snapshot counts even when the call opened before it" do
      # Opened before the snapshot was fetched, cost landed after: the cost is
      # in neither the Stripe balance nor an occurred_at-anchored delta. It
      # must count, so the sums anchor on completion time.
      seed_snapshot!(100, fetched_at: 5.seconds.ago)
      spend!(90, occurred_at: 2.minutes.ago, completed_at: Time.current)

      no_stripe! do
        assert_not BalanceGate.funded?("cus_gate_test")
      end
    end

    test "spend recorded before the snapshot was taken does not double-count" do
      spend!(400, occurred_at: 1.hour.ago)
      seed_snapshot!(100)

      no_stripe! do
        assert BalanceGate.funded?("cus_gate_test"), "pre-snapshot spend is already reflected in the snapshot"
      end
    end
  end
end
