# typed: false

require "test_helper"

module LLMGateway
  class PayerResolverTest < ActiveSupport::TestCase
    setup do
      @tenant, @collective, @user = create_tenant_collective_user
      @tenant.enable_feature_flag!("internal_ai_agents")
      Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

      @ai_agent = create_ai_agent(parent: @user)
      @task_run = AiAgentTaskRun.create!(
        tenant: @tenant,
        ai_agent: @ai_agent,
        initiated_by: @user,
        task: "Test task",
        max_steps: 10,
        status: "running",
      )
    end

    def create_funding_collective(members: [@user])
      collective = Collective.create!(
        tenant: @tenant,
        created_by: @user,
        name: "Agent Funding",
        handle: "fund-#{SecureRandom.hex(4)}",
        collective_type: "agent_funding",
      )
      members.each { |member| collective.add_user!(member) }
      collective
    end

    def create_funded_member!(collective, stripe_id:)
      member = create_user
      @tenant.add_user!(member)
      collective.add_user!(member)
      fund!(member, stripe_id: stripe_id)
      member
    end

    def fund!(user, stripe_id:, active: true, pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}")
      # A funded customer also has a generous fresh balance snapshot, so the
      # balance gate never reaches for Stripe in tests.
      seed_balance!(stripe_id, 1_000_000)
      StripeCustomer.create!(
        billable: user,
        stripe_id: stripe_id,
        active: active,
        pricing_plan_subscription_id: pricing_plan_subscription_id,
      )
    end

    def seed_balance!(stripe_id, cents, fetched_at: Time.current)
      StripeBalanceSnapshot.where(stripe_customer_id: stripe_id).delete_all
      StripeBalanceSnapshot.create!(stripe_customer_id: stripe_id, balance_cents: cents, fetched_at: fetched_at)
    end

    def create_stamped_billing_customer!
      seed_balance!("cus_individual", 1_000_000)
      billing_customer = StripeCustomer.create!(
        billable: @ai_agent,
        stripe_id: "cus_individual",
        active: true,
        pricing_plan_subscription_id: "bpps_test123",
      )
      @task_run.update!(stripe_customer_id: billing_customer.id)
      billing_customer
    end

    test "resolves a funding-collective agent to a funded member's customer" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_primary")
      create_funded_member!(funding, stripe_id: "cus_member_b")
      @ai_agent.update!(funding_collective: funding)

      result = PayerResolver.resolve(@task_run)
      assert_includes ["cus_primary", "cus_member_b"], result.payer_customer_id
    end

    test "pool selection is uniformly random across funded members" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_pool_a")
      create_funded_member!(funding, stripe_id: "cus_pool_b")
      create_funded_member!(funding, stripe_id: "cus_pool_c")
      @ai_agent.update!(funding_collective: funding)

      counts = Hash.new(0)
      300.times do
        counts[PayerResolver.resolve(@task_run).payer_customer_id] += 1
      end

      ["cus_pool_a", "cus_pool_b", "cus_pool_c"].each do |cus|
        # Expected 100 of 300 each; 60 is ~5 standard deviations below the
        # mean, so a false failure is vanishingly unlikely.
        assert_operator counts[cus], :>=, 60, "expected #{cus} to be picked roughly uniformly, got #{counts.inspect}"
      end
    end

    test "the funding collective takes precedence over a stamped billing customer" do
      create_stamped_billing_customer!
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_collective: funding)

      result = PayerResolver.resolve(@task_run)
      assert_equal "cus_pool_a", result.payer_customer_id
    end

    test "a pool result names the funding collective it drew from" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_collective: funding)

      result = PayerResolver.resolve(@task_run)
      assert_equal funding.id, result.funding_collective_id
    end

    test "an individual billing result names no funding collective" do
      create_stamped_billing_customer!

      result = PayerResolver.resolve(@task_run)
      assert_nil result.funding_collective_id
    end

    test "falls back to the stamped billing customer without a funding collective" do
      create_stamped_billing_customer!

      result = PayerResolver.resolve(@task_run)
      assert_equal "cus_individual", result.payer_customer_id
    end

    test "raises not_a_billed_task when there is no funding collective and no billing customer" do
      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "not_a_billed_task", error.code
    end

    test "members whose funding lapsed are skipped in draws" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_active")
      lapsed = create_user
      @tenant.add_user!(lapsed)
      funding.add_user!(lapsed)
      fund!(lapsed, stripe_id: "cus_lapsed", active: false)
      unsubscribed = create_user
      @tenant.add_user!(unsubscribed)
      funding.add_user!(unsubscribed)
      fund!(unsubscribed, stripe_id: "cus_unsubscribed", pricing_plan_subscription_id: nil)
      @ai_agent.update!(funding_collective: funding)

      20.times do
        assert_equal "cus_active", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "archived members are skipped in draws" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_active")
      departed = create_funded_member!(funding, stripe_id: "cus_departed")
      funding.collective_members.find_by!(user: departed).archive!
      @ai_agent.update!(funding_collective: funding)

      20.times do
        assert_equal "cus_active", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "non-human members never fund" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_human")
      funding.add_user!(@ai_agent)
      fund!(@ai_agent, stripe_id: "cus_agent_self")
      @ai_agent.update!(funding_collective: funding)

      20.times do
        assert_equal "cus_human", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    def record_spend!(stripe_id, cents, funding_collective_id: nil, agent: @ai_agent,
                      occurred_at: Time.current, completed_at: occurred_at)
      LLMUsageRecord.create!(
        selection_id: "sel_#{SecureRandom.uuid}",
        status: "completed",
        ai_agent_id: agent.id,
        payer_stripe_customer_id: stripe_id,
        origin_tenant_id: @tenant.id,
        funding_collective_id: funding_collective_id,
        estimated_cost_cents: cents,
        occurred_at: occurred_at,
        completed_at: completed_at,
      )
    end

    test "an agent over its daily spend cap is refused" do
      create_stamped_billing_customer!
      @ai_agent.update!(llm_daily_spend_cap_cents: 100)
      record_spend!("cus_individual", 100)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "spend_cap_exceeded", error.code
      assert_equal :too_many_requests, error.http_status
    end

    test "spend from previous days does not count against the daily cap" do
      create_stamped_billing_customer!
      @ai_agent.update!(llm_daily_spend_cap_cents: 100)
      record_spend!("cus_individual", 5_000, occurred_at: 2.days.ago)

      result = PayerResolver.resolve(@task_run)
      assert_equal "cus_individual", result.payer_customer_id
    end

    def open_call!(stripe_id, funding_collective_id: nil, agent: @ai_agent, occurred_at: Time.current)
      LLMUsageRecord.create!(
        selection_id: "sel_#{SecureRandom.uuid}",
        status: "pending",
        ai_agent_id: agent.id,
        payer_stripe_customer_id: stripe_id,
        origin_tenant_id: @tenant.id,
        funding_collective_id: funding_collective_id,
        occurred_at: occurred_at,
      )
    end

    test "in-flight calls reserve against the daily cap" do
      create_stamped_billing_customer!
      @ai_agent.update!(llm_daily_spend_cap_cents: 50)
      2.times { open_call!("cus_individual") }

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "spend_cap_exceeded", error.code
    end

    test "stale pending calls do not reserve against the daily cap" do
      create_stamped_billing_customer!
      @ai_agent.update!(llm_daily_spend_cap_cents: 50)
      2.times { open_call!("cus_individual", occurred_at: 20.minutes.ago) }

      result = PayerResolver.resolve(@task_run)
      assert_equal "cus_individual", result.payer_customer_id
    end

    test "in-flight draws reserve against the collective's draw ceiling" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_fresh")
      create_funded_member!(funding, stripe_id: "cus_tapped")
      funding.update!(member_daily_draw_cap_cents: 50)
      2.times { open_call!("cus_tapped", funding_collective_id: funding.id) }
      @ai_agent.update!(funding_collective: funding)

      20.times do
        assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "a call opened yesterday but completed today counts toward the daily cap" do
      create_stamped_billing_customer!
      @ai_agent.update!(llm_daily_spend_cap_cents: 100)
      record_spend!("cus_individual", 100, occurred_at: 25.hours.ago, completed_at: 1.minute.ago)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "spend_cap_exceeded", error.code
    end

    test "the daily spend cap also gates pool-funded agents" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_collective: funding, llm_daily_spend_cap_cents: 100)
      record_spend!("cus_pool_a", 150, funding_collective_id: funding.id)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "spend_cap_exceeded", error.code
    end

    test "pool members over the collective's daily draw ceiling are skipped" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_fresh")
      create_funded_member!(funding, stripe_id: "cus_tapped")
      funding.update!(member_daily_draw_cap_cents: 50)
      record_spend!("cus_tapped", 50, funding_collective_id: funding.id)
      @ai_agent.update!(funding_collective: funding)

      20.times do
        assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "draws for other pools do not count against a collective's ceiling" do
      funding = create_funding_collective
      other_pool = create_funding_collective
      fund!(@user, stripe_id: "cus_pool_a")
      funding.update!(member_daily_draw_cap_cents: 50)
      record_spend!("cus_pool_a", 500, funding_collective_id: other_pool.id)
      @ai_agent.update!(funding_collective: funding)

      assert_equal "cus_pool_a", PayerResolver.resolve(@task_run).payer_customer_id
    end

    test "dry members are skipped in draws" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_active")
      create_funded_member!(funding, stripe_id: "cus_dry")
      # Drained, recently verified — inside the verify throttle, so the gate
      # neither refetches nor draws from this member.
      seed_balance!("cus_dry", 0, fetched_at: 5.seconds.ago)
      @ai_agent.update!(funding_collective: funding)

      20.times do
        assert_equal "cus_active", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "an all-dry pool raises pool_exhausted" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_active")
      seed_balance!("cus_active", 0, fetched_at: 5.seconds.ago)
      @ai_agent.update!(funding_collective: funding)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "pool_exhausted", error.code
      assert_equal :payment_required, error.http_status
    end

    test "a dry individual billing customer is refused with balance_exhausted" do
      create_stamped_billing_customer!
      seed_balance!("cus_individual", 0, fetched_at: 5.seconds.ago)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "balance_exhausted", error.code
      assert_equal :payment_required, error.http_status
    end

    test "an archived funding collective suspends the agent" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_primary")
      @ai_agent.update!(funding_collective: funding)
      funding.update!(archived_at: Time.current, archived_by_id: @user.id)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "funding_collective_unavailable", error.code
      assert_equal :forbidden, error.http_status
    end

    test "raises pool_exhausted when no member is funded" do
      funding = create_funding_collective
      @ai_agent.update!(funding_collective: funding)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "pool_exhausted", error.code
      assert_equal :payment_required, error.http_status
    end

    test "raises no_primary when the principal's membership is archived after attach" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_primary")
      create_funded_member!(funding, stripe_id: "cus_member_b")
      @ai_agent.update!(funding_collective: funding)
      funding.collective_members.find_by!(user: @user).archive!

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "no_primary", error.code
      assert_equal :forbidden, error.http_status
    end

    # === resolve_for_agent (external gateway calls — no task run) ===

    def create_agent_billing_customer!(**overrides)
      seed_balance!("cus_agent_individual", 1_000_000)
      customer = StripeCustomer.create!(
        billable: @ai_agent,
        stripe_id: "cus_agent_individual",
        active: true,
        pricing_plan_subscription_id: "bpps_test123",
        **overrides,
      )
      @ai_agent.update!(stripe_customer_id: customer.id)
      customer
    end

    test "resolve_for_agent draws from the funding collective" do
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_collective: funding)

      result = PayerResolver.resolve_for_agent(@ai_agent)
      assert_equal "cus_pool_a", result.payer_customer_id
    end

    test "resolve_for_agent funding collective takes precedence over the agent's billing customer" do
      create_agent_billing_customer!
      funding = create_funding_collective
      fund!(@user, stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_collective: funding)

      result = PayerResolver.resolve_for_agent(@ai_agent)
      assert_equal "cus_pool_a", result.payer_customer_id
    end

    test "resolve_for_agent falls back to the agent's billing customer" do
      create_agent_billing_customer!

      result = PayerResolver.resolve_for_agent(@ai_agent)
      assert_equal "cus_agent_individual", result.payer_customer_id
    end

    test "resolve_for_agent raises not_funded when the agent has no billing customer" do
      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve_for_agent(@ai_agent)
      end
      assert_equal "not_funded", error.code
      assert_equal :payment_required, error.http_status
    end

    test "resolve_for_agent raises not_funded when the billing customer has no credit subscription" do
      create_agent_billing_customer!(pricing_plan_subscription_id: nil)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve_for_agent(@ai_agent)
      end
      assert_equal "not_funded", error.code
    end
  end
end
