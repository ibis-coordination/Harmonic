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

    # A pool on the agent's parent collective with the principal enrolled and
    # funded — the minimum arrangement the attach validation accepts. The
    # operator-managed funding_pools flag is on: the resolver treats it as a
    # kill switch.
    def create_funding_pool!(primary_stripe_id: "cus_primary", primary_cap: 500)
      FeatureFlagService.config["funding_pools"] ||= {}
      FeatureFlagService.config["funding_pools"]["app_enabled"] = true
      @tenant.enable_feature_flag!("funding_pools")
      @collective.enable_feature_flag!("funding_pools")
      pool = FundingPool.create!(tenant: @tenant, collective: @collective, created_by: @user, member_daily_draw_cap_cents: 500)
      fund!(@user, stripe_id: primary_stripe_id)
      pool.enroll!(@user, daily_draw_cap_cents: primary_cap)
      pool
    end

    def create_enrolled_member!(pool, stripe_id:, cap: 500)
      member = create_user
      @tenant.add_user!(member)
      @collective.add_user!(member)
      fund!(member, stripe_id: stripe_id)
      pool.enroll!(member, daily_draw_cap_cents: cap)
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

    test "resolves a pool-funded agent to an enrolled member's customer" do
      pool = create_funding_pool!
      create_enrolled_member!(pool, stripe_id: "cus_member_b")
      @ai_agent.update!(funding_pool: pool)

      result = PayerResolver.resolve(@task_run)
      assert_includes ["cus_primary", "cus_member_b"], result.payer_customer_id
    end

    test "pool selection is uniformly random across enrolled members" do
      pool = create_funding_pool!(primary_stripe_id: "cus_pool_a")
      create_enrolled_member!(pool, stripe_id: "cus_pool_b")
      create_enrolled_member!(pool, stripe_id: "cus_pool_c")
      @ai_agent.update!(funding_pool: pool)

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

    test "the funding pool takes precedence over a stamped billing customer" do
      create_stamped_billing_customer!
      pool = create_funding_pool!(primary_stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_pool: pool)

      result = PayerResolver.resolve(@task_run)
      assert_equal "cus_pool_a", result.payer_customer_id
    end

    test "a pool result names the pool it drew from" do
      pool = create_funding_pool!(primary_stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_pool: pool)

      result = PayerResolver.resolve(@task_run)
      assert_equal pool.id, result.funding_pool_id
    end

    test "an individual billing result names no funding pool" do
      create_stamped_billing_customer!

      result = PayerResolver.resolve(@task_run)
      assert_nil result.funding_pool_id
    end

    test "falls back to the stamped billing customer without a funding pool" do
      create_stamped_billing_customer!

      result = PayerResolver.resolve(@task_run)
      assert_equal "cus_individual", result.payer_customer_id
    end

    test "raises not_a_billed_task when there is no funding pool and no billing customer" do
      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "not_a_billed_task", error.code
    end

    test "members whose funding lapsed after enrolling are skipped in draws" do
      pool = create_funding_pool!(primary_stripe_id: "cus_active")
      lapsed = create_enrolled_member!(pool, stripe_id: "cus_lapsed")
      lapsed.stripe_customer.update!(active: false)
      unsubscribed = create_enrolled_member!(pool, stripe_id: "cus_unsubscribed")
      unsubscribed.stripe_customer.update!(pricing_plan_subscription_id: nil)
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_active", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "withdrawn enrollments are skipped in draws" do
      pool = create_funding_pool!(primary_stripe_id: "cus_active")
      departed = create_enrolled_member!(pool, stripe_id: "cus_departed")
      pool.enrollments.find_by!(user: departed).withdraw!
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_active", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "enrolled members who left the collective are skipped in draws" do
      pool = create_funding_pool!(primary_stripe_id: "cus_active")
      departed = create_enrolled_member!(pool, stripe_id: "cus_departed")
      @collective.collective_members.find_by!(user: departed).archive!
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_active", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "non-human enrollments never fund" do
      # The enrollment gate refuses agents, so force the bad row past
      # validation — the resolver must not trust enrollment rows.
      pool = create_funding_pool!(primary_stripe_id: "cus_human")
      other_agent = create_ai_agent(parent: @user)
      @collective.add_user!(other_agent)
      fund!(other_agent, stripe_id: "cus_agent_self")
      FundingPoolEnrollment.new(tenant: @tenant, collective: @collective, funding_pool: pool, user: other_agent,
                                daily_draw_cap_cents: 500)
                           .save!(validate: false)
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_human", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    def record_spend!(stripe_id, cents, funding_pool_id: nil, agent: @ai_agent,
                      occurred_at: Time.current, completed_at: occurred_at)
      LLMUsageRecord.create!(
        selection_id: "sel_#{SecureRandom.uuid}",
        status: "completed",
        ai_agent_id: agent.id,
        payer_stripe_customer_id: stripe_id,
        origin_tenant_id: @tenant.id,
        funding_pool_id: funding_pool_id,
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

    def open_call!(stripe_id, funding_pool_id: nil, agent: @ai_agent, occurred_at: Time.current)
      LLMUsageRecord.create!(
        selection_id: "sel_#{SecureRandom.uuid}",
        status: "pending",
        ai_agent_id: agent.id,
        payer_stripe_customer_id: stripe_id,
        origin_tenant_id: @tenant.id,
        funding_pool_id: funding_pool_id,
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

    test "in-flight draws reserve against the pool's draw ceiling" do
      pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
      create_enrolled_member!(pool, stripe_id: "cus_tapped")
      pool.update!(member_daily_draw_cap_cents: 50)
      2.times { open_call!("cus_tapped", funding_pool_id: pool.id) }
      @ai_agent.update!(funding_pool: pool)

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
      pool = create_funding_pool!(primary_stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_pool: pool, llm_daily_spend_cap_cents: 100)
      record_spend!("cus_pool_a", 150, funding_pool_id: pool.id)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "spend_cap_exceeded", error.code
    end

    test "pool members over the pool's daily draw ceiling are skipped" do
      pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
      create_enrolled_member!(pool, stripe_id: "cus_tapped")
      pool.update!(member_daily_draw_cap_cents: 50)
      record_spend!("cus_tapped", 50, funding_pool_id: pool.id)
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "a member is skipped once this pool's draws reach their own enrollment ceiling" do
      pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
      create_enrolled_member!(pool, stripe_id: "cus_low_consent", cap: 50)
      record_spend!("cus_low_consent", 50, funding_pool_id: pool.id)
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "the pool ceiling binds when lower than a member's own enrollment ceiling" do
      pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
      create_enrolled_member!(pool, stripe_id: "cus_generous", cap: 10_000)
      pool.update!(member_daily_draw_cap_cents: 50)
      record_spend!("cus_generous", 50, funding_pool_id: pool.id)
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "a member under their own lower ceiling is still drawable" do
      pool = create_funding_pool!(primary_stripe_id: "cus_primary", primary_cap: 100)
      record_spend!("cus_primary", 60, funding_pool_id: pool.id)
      @ai_agent.update!(funding_pool: pool)

      assert_equal "cus_primary", PayerResolver.resolve(@task_run).payer_customer_id
    end

    test "draws for other pools do not count against a pool's ceiling" do
      pool = create_funding_pool!(primary_stripe_id: "cus_pool_a")
      other_collective = create_collective(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")
      other_collective.add_user!(@user)
      other_pool = FundingPool.create!(tenant: @tenant, collective: other_collective, created_by: @user, member_daily_draw_cap_cents: 500)
      pool.update!(member_daily_draw_cap_cents: 50)
      record_spend!("cus_pool_a", 500, funding_pool_id: other_pool.id)
      @ai_agent.update!(funding_pool: pool)

      assert_equal "cus_pool_a", PayerResolver.resolve(@task_run).payer_customer_id
    end

    test "pool selection verifies only the sampled member's balance" do
      pool = create_funding_pool!(primary_stripe_id: "cus_stale_a")
      create_enrolled_member!(pool, stripe_id: "cus_stale_b")
      create_enrolled_member!(pool, stripe_id: "cus_stale_c")
      # All snapshots stale: a per-member gate check would refetch every one
      # of them from Stripe, serially, on the per-call path.
      ["cus_stale_a", "cus_stale_b", "cus_stale_c"].each do |stripe_id|
        seed_balance!(stripe_id, 1_000_000, fetched_at: 11.minutes.ago)
      end
      @ai_agent.update!(funding_pool: pool)

      fetches = 0
      StripeService.stub :get_credit_balance, ->(_) { fetches += 1; 1_000_000 } do
        PayerResolver.resolve(@task_run)
      end
      assert_equal 1, fetches, "only the sampled member's balance is verified, not the whole pool's"
    end

    test "dry members are skipped in draws" do
      pool = create_funding_pool!(primary_stripe_id: "cus_active")
      create_enrolled_member!(pool, stripe_id: "cus_dry")
      # Drained, recently verified — inside the verify throttle, so the gate
      # neither refetches nor draws from this member.
      seed_balance!("cus_dry", 0, fetched_at: 5.seconds.ago)
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_active", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "an all-dry pool raises pool_exhausted" do
      pool = create_funding_pool!(primary_stripe_id: "cus_active")
      seed_balance!("cus_active", 0, fetched_at: 5.seconds.ago)
      @ai_agent.update!(funding_pool: pool)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "pool_exhausted", error.code
      assert_equal :payment_required, error.http_status
    end

    test "a closed funding pool suspends the agent" do
      pool = create_funding_pool!
      @ai_agent.update!(funding_pool: pool)
      pool.archive!

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "funding_collective_unavailable", error.code
      assert_equal :forbidden, error.http_status
    end

    test "disabling the funding_pools flag suspends pool draws" do
      pool = create_funding_pool!
      @ai_agent.update!(funding_pool: pool)
      @collective.disable_feature_flag!("funding_pools")

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "funding_collective_unavailable", error.code
      assert_equal :forbidden, error.http_status
    end

    test "archiving the pool's collective suspends the agent" do
      pool = create_funding_pool!
      @ai_agent.update!(funding_pool: pool)
      @collective.update!(archived_at: Time.current, archived_by_id: @user.id)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "funding_collective_unavailable", error.code
      assert_equal :forbidden, error.http_status
    end

    test "raises pool_exhausted when no enrolled member is funded" do
      pool = create_funding_pool!
      @ai_agent.update!(funding_pool: pool)
      @user.stripe_customer.update!(active: false)

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "pool_exhausted", error.code
      assert_equal :payment_required, error.http_status
    end

    test "raises no_primary when the principal withdraws after attach" do
      pool = create_funding_pool!
      create_enrolled_member!(pool, stripe_id: "cus_member_b")
      @ai_agent.update!(funding_pool: pool)
      pool.enrollments.find_by!(user: @user).withdraw!

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "no_primary", error.code
      assert_equal :forbidden, error.http_status
    end

    test "raises no_primary when the principal's membership is archived after attach" do
      pool = create_funding_pool!
      create_enrolled_member!(pool, stripe_id: "cus_member_b")
      @ai_agent.update!(funding_pool: pool)
      @collective.collective_members.find_by!(user: @user).archive!

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

    test "resolve_for_agent draws from the funding pool" do
      pool = create_funding_pool!(primary_stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_pool: pool)

      result = PayerResolver.resolve_for_agent(@ai_agent)
      assert_equal "cus_pool_a", result.payer_customer_id
    end

    test "resolve_for_agent funding pool takes precedence over the agent's billing customer" do
      create_agent_billing_customer!
      pool = create_funding_pool!(primary_stripe_id: "cus_pool_a")
      @ai_agent.update!(funding_pool: pool)

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
