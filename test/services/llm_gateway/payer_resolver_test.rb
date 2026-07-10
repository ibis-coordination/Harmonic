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
      StripeCustomer.create!(
        billable: user,
        stripe_id: stripe_id,
        active: active,
        pricing_plan_subscription_id: pricing_plan_subscription_id,
      )
    end

    def create_stamped_billing_customer!
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
