# typed: false

require "test_helper"

module LLMGateway
  class UsageReportTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    setup do
      @tenant, @collective, @user = create_tenant_collective_user
      @tenant.enable_feature_flag!("internal_ai_agents")
      Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
      @ai_agent = create_ai_agent(parent: @user)
    end

    def create_funding_pool!(primary_stripe_id: "cus_primary", primary_cap: 500)
      FeatureFlagService.config["funding_pools"] ||= {}
      FeatureFlagService.config["funding_pools"]["app_enabled"] = true
      @tenant.enable_feature_flag!("funding_pools")
      @collective.enable_feature_flag!("funding_pools")
      pool = FundingPool.create!(tenant: @tenant, collective: @collective, created_by: @user, member_draw_cap_cents: 500)
      fund!(@user, stripe_id: primary_stripe_id)
      pool.enroll!(@user, draw_cap_cents: primary_cap)
      pool
    end

    def create_enrolled_member!(pool, stripe_id:, cap: 500, name: "Pool Member")
      member = create_user(name: name)
      @tenant.add_user!(member)
      @collective.add_user!(member)
      fund!(member, stripe_id: stripe_id)
      pool.enroll!(member, draw_cap_cents: cap)
      member
    end

    def create_other_pool!
      other = create_collective(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")
      other.add_user!(@user)
      FundingPool.create!(tenant: @tenant, collective: other, created_by: @user, member_draw_cap_cents: 500)
    end

    def fund!(user, stripe_id:, active: true, pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}")
      StripeCustomer.create!(
        billable: user,
        stripe_id: stripe_id,
        active: active,
        pricing_plan_subscription_id: pricing_plan_subscription_id,
      )
    end

    def record_spend!(stripe_id, cents, funding_pool_id: nil, agent: @ai_agent, status: "completed",
                      occurred_at: Time.current, completed_at: occurred_at)
      LLMUsageRecord.create!(
        selection_id: "sel_#{SecureRandom.uuid}",
        status: status,
        ai_agent_id: agent.id,
        payer_stripe_customer_id: stripe_id,
        origin_tenant_id: @tenant.id,
        funding_pool_id: funding_pool_id,
        estimated_cost_cents: status == "completed" ? cents : nil,
        occurred_at: occurred_at,
        completed_at: status == "completed" ? completed_at : nil,
      )
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

    # === pool_report ===

    test "pool_report sums completed spend per member and per agent within the window" do
      pool = create_funding_pool!(primary_stripe_id: "cus_primary")
      member_b = create_enrolled_member!(pool, stripe_id: "cus_member_b", name: "Member B")
      agent_2 = create_ai_agent(parent: @user, name: "Agent Two")
      record_spend!("cus_primary", 100, funding_pool_id: pool.id, agent: @ai_agent)
      record_spend!("cus_member_b", 250, funding_pool_id: pool.id, agent: agent_2)

      report = UsageReport.pool_report(pool)

      assert_equal 350, report[:total_cents]
      member_spend = report[:member_rows].to_h { |r| [r[:user].id, r[:spend_cents]] }
      assert_equal 100, member_spend[@user.id]
      assert_equal 250, member_spend[member_b.id]
      agent_spend = report[:agent_rows].to_h { |r| [r[:agent].id, r[:spend_cents]] }
      assert_equal 100, agent_spend[@ai_agent.id]
      assert_equal 250, agent_spend[agent_2.id]
    end

    test "pool_report excludes failed rows, other pools, and rows older than the window" do
      pool = create_funding_pool!(primary_stripe_id: "cus_primary")
      other_pool = create_other_pool!
      record_spend!("cus_primary", 100, funding_pool_id: pool.id)
      record_spend!("cus_primary", 500, funding_pool_id: pool.id, occurred_at: 40.days.ago, completed_at: 40.days.ago)
      record_spend!("cus_primary", 700, funding_pool_id: other_pool.id)
      record_spend!("cus_primary", 900, funding_pool_id: pool.id, status: "failed")

      report = UsageReport.pool_report(pool)

      assert_equal 100, report[:total_cents]
    end

    test "pool_report includes zero-spend active enrollees" do
      pool = create_funding_pool!(primary_stripe_id: "cus_primary")
      member_b = create_enrolled_member!(pool, stripe_id: "cus_member_b", name: "Member B")
      record_spend!("cus_primary", 100, funding_pool_id: pool.id)

      report = UsageReport.pool_report(pool)

      row = report[:member_rows].find { |r| r[:user].id == member_b.id }
      assert_not_nil row, "a zero-spend active enrollee must still appear"
      assert_equal 0, row[:spend_cents]
    end

    test "pool_report includes a withdrawn member who has window spend" do
      pool = create_funding_pool!(primary_stripe_id: "cus_primary")
      departed = create_enrolled_member!(pool, stripe_id: "cus_departed", name: "Departed Member")
      record_spend!("cus_departed", 80, funding_pool_id: pool.id)
      pool.enrollments.find_by!(user: departed).withdraw!

      report = UsageReport.pool_report(pool)

      row = report[:member_rows].find { |r| r[:user].id == departed.id }
      assert_not_nil row, "a withdrawn member with window spend must still appear"
      assert_equal 80, row[:spend_cents]
    end

    test "pool_report counts pending and stale pending rows" do
      pool = create_funding_pool!(primary_stripe_id: "cus_primary")
      open_call!("cus_primary", funding_pool_id: pool.id, occurred_at: 1.minute.ago)
      open_call!("cus_primary", funding_pool_id: pool.id, occurred_at: 16.minutes.ago)

      report = UsageReport.pool_report(pool)

      assert_equal 2, report[:pending_count]
      assert_equal 1, report[:stale_pending_count]
    end

    # === funding_report ===

    test "funding_report returns nil for a user with no stripe customer" do
      other = create_user(name: "No Customer")
      @tenant.add_user!(other)

      assert_nil UsageReport.funding_report(other)
    end

    test "funding_report reports per-enrollment draws, agents, and totals; direct spend counts but is not a pool draw" do
      pool = create_funding_pool!(primary_stripe_id: "cus_primary")
      agent_2 = create_ai_agent(parent: @user, name: "Agent Two")
      record_spend!("cus_primary", 100, funding_pool_id: pool.id, agent: @ai_agent)
      record_spend!("cus_primary", 40, funding_pool_id: nil, agent: agent_2)

      report = UsageReport.funding_report(@user)

      assert_equal 140, report[:total_billed_cents]
      assert_equal 100, report[:pool_draw_cents]
      enrollment_row = report[:enrollment_rows].find { |r| r[:enrollment].funding_pool_id == pool.id }
      assert_not_nil enrollment_row
      assert_equal 100, enrollment_row[:drawn_cents]
      agent_spend = report[:agent_rows].to_h { |r| [r[:agent].id, r[:spend_cents]] }
      assert_equal 100, agent_spend[@ai_agent.id]
      assert_equal 40, agent_spend[agent_2.id]
    end

    test "funding_report excludes rows paid by a different customer" do
      pool = create_funding_pool!(primary_stripe_id: "cus_primary")
      create_enrolled_member!(pool, stripe_id: "cus_member_b", name: "Member B")
      record_spend!("cus_primary", 100, funding_pool_id: pool.id)
      record_spend!("cus_member_b", 999, funding_pool_id: pool.id)

      report = UsageReport.funding_report(@user)

      assert_equal 100, report[:total_billed_cents]
    end
  end
end
