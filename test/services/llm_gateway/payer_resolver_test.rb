# typed: false

require "test_helper"

module LLMGateway
  class PayerResolverTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

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
    # tenant has stripe_billing (draws only happen on billing tenants) and
    # the operator-managed funding_pools flag is on at every level: the
    # resolver treats pool availability as a kill switch.
    def create_funding_pool!(primary_stripe_id: "cus_primary", primary_cap: 500)
      FeatureFlagService.config["stripe_billing"] ||= {}
      FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
      @tenant.enable_feature_flag!("stripe_billing")
      FeatureFlagService.config["funding_pools"] ||= {}
      FeatureFlagService.config["funding_pools"]["app_enabled"] = true
      @tenant.enable_feature_flag!("funding_pools")
      @collective.enable_feature_flag!("funding_pools")
      pool = FundingPool.create!(tenant: @tenant, collective: @collective, created_by: @user, member_draw_cap_cents: 500)
      fund!(@user, stripe_id: primary_stripe_id)
      pool.enroll!(@user, draw_cap_cents: primary_cap)
      pool
    end

    def create_enrolled_member!(pool, stripe_id:, cap: 500)
      member = create_user
      @tenant.add_user!(member)
      @collective.add_user!(member)
      fund!(member, stripe_id: stripe_id)
      pool.enroll!(member, draw_cap_cents: cap)
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

    test "a pool result carries the terms the draw was authorized against" do
      pool = create_funding_pool!(primary_cap: 300)
      @ai_agent.update!(funding_pool: pool)
      enrollment = pool.enrollments.find_by!(user: @user)

      result = PayerResolver.resolve(@task_run)

      assert_equal "cus_primary", result.payer_customer_id
      assert_equal enrollment.id, result.funding_pool_enrollment_id
      assert_equal 300, result.enrollment_draw_cap_cents, "the selected member's own ceiling"
      assert_equal "day", result.enrollment_draw_cap_period
      assert_equal 500, result.pool_member_draw_cap_cents, "the pool's per-member ceiling"
      assert_equal "day", result.pool_member_draw_cap_period
    end

    test "an individual billing result carries no authorizing terms" do
      create_stamped_billing_customer!

      result = PayerResolver.resolve(@task_run)

      assert_nil result.funding_pool_enrollment_id
      assert_nil result.enrollment_draw_cap_cents
      assert_nil result.enrollment_draw_cap_period
      assert_nil result.pool_member_draw_cap_cents
      assert_nil result.pool_member_draw_cap_period
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

    test "members without a pricing-plan subscription are skipped; an identity-subscription lapse is not" do
      # The identity ($3/month) subscription and pool funding are separate
      # concerns: draws spend prepaid credits, which need only the
      # pricing-plan subscription. A member whose identity subscription
      # lapsed (active: false) keeps funding draws.
      pool = create_funding_pool!(primary_stripe_id: "cus_active")
      lapsed = create_enrolled_member!(pool, stripe_id: "cus_lapsed")
      lapsed.stripe_customer.update!(active: false)
      unsubscribed = create_enrolled_member!(pool, stripe_id: "cus_unsubscribed")
      unsubscribed.stripe_customer.update!(pricing_plan_subscription_id: nil)
      @ai_agent.update!(funding_pool: pool)

      drawn = Set.new
      40.times { drawn << PayerResolver.resolve(@task_run).payer_customer_id }
      assert_includes drawn, "cus_lapsed", "an identity-subscription lapse must not exclude a plan-subscribed member"
      assert_not_includes drawn, "cus_unsubscribed"
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
                                draw_cap_cents: 500)
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

    test "an under-reserving pending call is allowed, then its real cost gates once it completes" do
      create_stamped_billing_customer!
      @ai_agent.update!(llm_daily_spend_cap_cents: 100)
      call = open_call!("cus_individual")

      # One in-flight call reserves only 25¢, under the 100¢ cap — still drawable.
      assert_equal "cus_individual", PayerResolver.resolve(@task_run).payer_customer_id

      # It completes at 200¢, far above its reservation: now over the cap.
      call.update!(status: "completed", estimated_cost_cents: 200, completed_at: Time.current)
      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "spend_cap_exceeded", error.code
    end

    test "a stale pending call reserves nothing, but its completion counts against the daily cap" do
      create_stamped_billing_customer!
      @ai_agent.update!(llm_daily_spend_cap_cents: 100)
      call = open_call!("cus_individual", occurred_at: 20.minutes.ago)

      # 20 minutes old: outside the reservation window, so it holds no reserve — drawable.
      assert_equal "cus_individual", PayerResolver.resolve(@task_run).payer_customer_id

      # Completing it lands the full 100¢ inside today's window — now at the cap.
      call.update!(status: "completed", estimated_cost_cents: 100, completed_at: Time.current)
      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "spend_cap_exceeded", error.code
    end

    test "in-flight draws reserve against the pool's draw ceiling" do
      pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
      create_enrolled_member!(pool, stripe_id: "cus_tapped")
      pool.update!(member_draw_cap_cents: 50)
      2.times { open_call!("cus_tapped", funding_pool_id: pool.id) }
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "a call opened yesterday but completed today counts toward the daily cap" do
      # Anchored at noon so "1 minute ago" cannot slip past the cap's
      # midnight-UTC boundary when the test itself runs near midnight.
      travel_to Time.utc(2026, 7, 15, 12) do
        create_stamped_billing_customer!
        @ai_agent.update!(llm_daily_spend_cap_cents: 100)
        record_spend!("cus_individual", 100, occurred_at: 25.hours.ago, completed_at: 1.minute.ago)

        error = assert_raises(PayerResolver::ResolutionError) do
          PayerResolver.resolve(@task_run)
        end
        assert_equal "spend_cap_exceeded", error.code
      end
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
      pool.update!(member_draw_cap_cents: 50)
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
      pool.update!(member_draw_cap_cents: 50)
      record_spend!("cus_generous", 50, funding_pool_id: pool.id)
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "raising the pool ceiling does not raise an existing enrollee's exposure" do
      # Enrolled while the pool ceiling was 500 — the enrollment snapshots
      # that number as the member's own consent, never a live reference.
      pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
      create_enrolled_member!(pool, stripe_id: "cus_snapshot", cap: 500)
      pool.update!(member_draw_cap_cents: 10_000)
      record_spend!("cus_snapshot", 500, funding_pool_id: pool.id)
      @ai_agent.update!(funding_pool: pool)

      20.times do
        assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "lowering a member's enrollment ceiling below what this pool has drawn skips them at once" do
      pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
      member = create_enrolled_member!(pool, stripe_id: "cus_lowered", cap: 500)
      record_spend!("cus_lowered", 300, funding_pool_id: pool.id)
      # Re-enroll at a lower ceiling: 300 already drawn now sits at or above it.
      pool.enroll!(member, draw_cap_cents: 200)
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

    # === Ceiling periods. The schema and resolver support day/week/month
    # windows; every current UI surface writes "day". Frozen mid-week,
    # mid-month so "earlier this week/month" is distinct from "today". ===

    test "a weekly member ceiling counts draws since the start of the UTC week" do
      travel_to Time.utc(2026, 7, 15, 12) do # Wednesday, July 15
        pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
        member = create_enrolled_member!(pool, stripe_id: "cus_weekly")
        pool.enrollments.find_by!(user: member).update!(draw_cap_cents: 100, draw_cap_period: "week")
        # Monday's draw: outside today's window, inside this week's.
        record_spend!("cus_weekly", 100, funding_pool_id: pool.id, occurred_at: 2.days.ago)
        @ai_agent.update!(funding_pool: pool)

        20.times do
          assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
        end
      end
    end

    test "last week's draws do not count against a weekly ceiling" do
      travel_to Time.utc(2026, 7, 15, 12) do
        pool = create_funding_pool!(primary_stripe_id: "cus_primary")
        pool.enrollments.find_by!(user: @user).update!(draw_cap_cents: 100, draw_cap_period: "week")
        record_spend!("cus_primary", 100, funding_pool_id: pool.id, occurred_at: 8.days.ago)
        @ai_agent.update!(funding_pool: pool)

        assert_equal "cus_primary", PayerResolver.resolve(@task_run).payer_customer_id
      end
    end

    test "a monthly member ceiling counts draws since the start of the UTC month" do
      travel_to Time.utc(2026, 7, 15, 12) do
        pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
        member = create_enrolled_member!(pool, stripe_id: "cus_monthly")
        pool.enrollments.find_by!(user: member).update!(draw_cap_cents: 100, draw_cap_period: "month")
        record_spend!("cus_monthly", 100, funding_pool_id: pool.id, occurred_at: 10.days.ago)
        @ai_agent.update!(funding_pool: pool)

        20.times do
          assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
        end
      end
    end

    test "pool and member ceilings with different periods are enforced independently" do
      travel_to Time.utc(2026, 7, 15, 12) do
        # Pool: $1.00 per member per WEEK. Member's own ceiling: $5.00 per DAY.
        # Monday's draw fills the pool's weekly window even though today's
        # window is empty — no cross-period normalization, each bound stands.
        pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
        create_enrolled_member!(pool, stripe_id: "cus_week_bound")
        pool.update!(member_draw_cap_cents: 100, member_draw_cap_period: "week")
        record_spend!("cus_week_bound", 100, funding_pool_id: pool.id, occurred_at: 2.days.ago)
        record_spend!("cus_fresh", 100, funding_pool_id: pool.id, occurred_at: 8.days.ago)
        @ai_agent.update!(funding_pool: pool)

        20.times do
          assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
        end
      end
    end

    test "a draw completed before the UTC week start does not count against a weekly ceiling" do
      travel_to Time.utc(2026, 7, 15, 12) do # Wednesday, July 15
        pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
        member = create_enrolled_member!(pool, stripe_id: "cus_weekly")
        pool.enrollments.find_by!(user: member).update!(draw_cap_cents: 100, draw_cap_period: "week")
        # Sunday July 12 sits in the prior UTC week — the window opens Monday July 13.
        record_spend!("cus_weekly", 100, funding_pool_id: pool.id, occurred_at: Time.utc(2026, 7, 12, 12))
        @ai_agent.update!(funding_pool: pool)

        drawn = Set.new
        40.times { drawn << PayerResolver.resolve(@task_run).payer_customer_id }
        assert_includes drawn, "cus_weekly", "a draw before the week start must leave the member drawable"
      end
    end

    test "the pool's monthly ceiling counts draws since the start of the UTC month" do
      travel_to Time.utc(2026, 7, 15, 12) do
        pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
        create_enrolled_member!(pool, stripe_id: "cus_tapped")
        pool.update!(member_draw_cap_cents: 100, member_draw_cap_period: "month")
        record_spend!("cus_tapped", 100, funding_pool_id: pool.id, occurred_at: 10.days.ago)
        @ai_agent.update!(funding_pool: pool)

        20.times do
          assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
        end
      end
    end

    test "a monthly enrollment ceiling counts draws from the first of the UTC month, not before" do
      travel_to Time.utc(2026, 7, 15, 12) do
        pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
        before = create_enrolled_member!(pool, stripe_id: "cus_prior_month")
        on_start = create_enrolled_member!(pool, stripe_id: "cus_month_start")
        [before, on_start].each do |m|
          pool.enrollments.find_by!(user: m).update!(draw_cap_cents: 100, draw_cap_period: "month")
        end
        # June 30 sits in the prior month; July 1 opens the current window.
        record_spend!("cus_prior_month", 100, funding_pool_id: pool.id, occurred_at: Time.utc(2026, 6, 30, 12))
        record_spend!("cus_month_start", 100, funding_pool_id: pool.id, occurred_at: Time.utc(2026, 7, 1, 12))
        @ai_agent.update!(funding_pool: pool)

        drawn = Set.new
        60.times { drawn << PayerResolver.resolve(@task_run).payer_customer_id }
        assert_includes drawn, "cus_prior_month", "a draw before the month start must leave the member drawable"
        assert_not_includes drawn, "cus_month_start", "a draw on the first of the month fills the monthly ceiling"
      end
    end

    test "switching an enrollment to a monthly window counts this month's earlier draws" do
      travel_to Time.utc(2026, 7, 15, 12) do
        pool = create_funding_pool!(primary_stripe_id: "cus_fresh")
        member = create_enrolled_member!(pool, stripe_id: "cus_switched", cap: 500)
        # Window sums anchor on completed_at within the window now in force, whatever period that is.
        record_spend!("cus_switched", 40, funding_pool_id: pool.id, occurred_at: 5.days.ago)
        pool.enrollments.find_by!(user: member).update!(draw_cap_cents: 30, draw_cap_period: "month")
        @ai_agent.update!(funding_pool: pool)

        20.times do
          assert_equal "cus_fresh", PayerResolver.resolve(@task_run).payer_customer_id
        end
      end
    end

    test "draws for other pools do not count against a pool's ceiling" do
      pool = create_funding_pool!(primary_stripe_id: "cus_pool_a")
      other_collective = create_collective(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")
      other_collective.add_user!(@user)
      other_pool = FundingPool.create!(tenant: @tenant, collective: other_collective, created_by: @user, member_draw_cap_cents: 500)
      pool.update!(member_draw_cap_cents: 50)
      record_spend!("cus_pool_a", 500, funding_pool_id: other_pool.id)
      @ai_agent.update!(funding_pool: pool)

      assert_equal "cus_pool_a", PayerResolver.resolve(@task_run).payer_customer_id
    end

    test "a member enrolled in two pools has each pool's ceiling counted only against that pool's draws" do
      # cus_shared belongs to pool A (daily window) and pool B (monthly window),
      # each funded by its own attached agent. A 100¢ draw sits in each pool;
      # both are under their pool's 150¢ ceiling, but a leaked cross-pool draw
      # would push either over — so each stays drawable only because the sums
      # filter on funding_pool_id.
      pool_a = create_funding_pool!(primary_stripe_id: "cus_shared", primary_cap: 150)
      pool_a.update!(member_draw_cap_cents: 150, member_draw_cap_period: "day")

      other_collective = create_collective(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")
      other_collective.add_user!(@user)
      other_collective.enable_feature_flag!("funding_pools")
      pool_b = FundingPool.create!(tenant: @tenant, collective: other_collective, created_by: @user,
                                   member_draw_cap_cents: 150, member_draw_cap_period: "month")
      pool_b.enroll!(@user, draw_cap_cents: 150)

      @ai_agent.update!(funding_pool: pool_a)
      agent_b = create_ai_agent(parent: @user)
      # The attach validation reads the enrollment through the pool's own
      # collective, so scope the thread there for the write.
      Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: other_collective.handle)
      agent_b.update!(funding_pool: pool_b)
      Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
      task_run_b = AiAgentTaskRun.create!(
        tenant: @tenant, ai_agent: agent_b, initiated_by: @user, task: "Test task B", max_steps: 10, status: "running",
      )

      record_spend!("cus_shared", 100, funding_pool_id: pool_a.id)
      record_spend!("cus_shared", 100, funding_pool_id: pool_b.id, agent: agent_b)

      assert_equal "cus_shared", PayerResolver.resolve(@task_run).payer_customer_id
      assert_equal "cus_shared", PayerResolver.resolve(task_run_b).payer_customer_id
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
      @user.stripe_customer.update!(pricing_plan_subscription_id: nil)

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

    # === Collective-principaled system agents (personas) ===

    def create_pool_funded_trio!(pool)
      trio = PersonaSeeder.ensure_for(@collective, Personas::CADENCE)
      trio.update!(funding_pool: pool)
      AiAgentTaskRun.create!(
        tenant: @tenant,
        ai_agent: trio,
        initiated_by: @user,
        task: "Trio task",
        max_steps: 10,
        status: "running",
      )
    end

    test "a collective-principaled trio draws from its own pool without an enrolled principal" do
      pool = create_funding_pool!
      trio_run = create_pool_funded_trio!(pool)

      result = PayerResolver.resolve(trio_run)
      assert_equal "cus_primary", result.payer_customer_id
      assert_equal pool.id, result.funding_pool_id
    end

    test "a trio draw stamps the drawn member's enrollment receipt" do
      pool = create_funding_pool!(primary_cap: 300)
      trio_run = create_pool_funded_trio!(pool)

      result = PayerResolver.resolve(trio_run)
      assert_equal pool.enrollments.find_by!(user: @user).id, result.funding_pool_enrollment_id
      assert_equal 300, result.enrollment_draw_cap_cents
    end

    test "a trio draw raises pool_exhausted when no enrolled member is funded" do
      pool = create_funding_pool!
      trio_run = create_pool_funded_trio!(pool)
      pool.enrollments.find_by!(user: @user).withdraw!

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(trio_run)
      end
      assert_equal "pool_exhausted", error.code
    end

    test "the funding_pools kill switch suspends trio draws too" do
      pool = create_funding_pool!
      trio_run = create_pool_funded_trio!(pool)
      @collective.disable_feature_flag!("funding_pools")

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(trio_run)
      end
      assert_equal "funding_collective_unavailable", error.code
    end

    test "a paid-tier collective's pool draws without the operator collective flag" do
      pool = create_funding_pool!
      @collective.disable_feature_flag!("funding_pools")
      @collective.update!(tier: Collective::TIER_PAID)
      @ai_agent.update!(funding_pool: pool)

      result = PayerResolver.resolve(@task_run)
      assert_equal "cus_primary", result.payer_customer_id
    end

    test "losing the paid tier suspends a self-serve pool's draws" do
      pool = create_funding_pool!
      @collective.disable_feature_flag!("funding_pools")
      @collective.update!(tier: Collective::TIER_PAID)
      @ai_agent.update!(funding_pool: pool)
      @collective.mark_lapsed!

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "funding_collective_unavailable", error.code
    end

    test "a system agent principaled by a different collective still requires an enrolled principal" do
      pool = create_funding_pool!
      other = create_collective(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")
      other_trio = PersonaSeeder.ensure_for(other, Personas::CADENCE)
      other_trio.update_column(:funding_pool_id, pool.id)
      run = AiAgentTaskRun.create!(
        tenant: @tenant,
        ai_agent: other_trio,
        initiated_by: @user,
        task: "Cross-collective trio task",
        max_steps: 10,
        status: "running",
      )

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(run)
      end
      assert_equal "no_primary", error.code
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

    test "resolve_for_agent falls back to the principal's customer when the agent is unstamped" do
      # Agents created before their principal had a Stripe customer are never
      # stamped; the principal's own customer funds them. active: false pins
      # that the identity subscription is not required on this path either.
      fund!(@user, stripe_id: "cus_principal", active: false)

      result = PayerResolver.resolve_for_agent(@ai_agent)
      assert_equal "cus_principal", result.payer_customer_id
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
