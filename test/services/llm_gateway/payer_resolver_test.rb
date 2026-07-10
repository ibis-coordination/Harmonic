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

      @previous_pool_config = ENV.fetch(PayerResolver::POOL_CONFIG_ENV, nil)
    end

    teardown do
      if @previous_pool_config.nil?
        ENV.delete(PayerResolver::POOL_CONFIG_ENV)
      else
        ENV[PayerResolver::POOL_CONFIG_ENV] = @previous_pool_config
      end
    end

    def configure_pool!(customer_ids, agent_id: @ai_agent.id)
      ENV[PayerResolver::POOL_CONFIG_ENV] = { agent_id => customer_ids }.to_json
    end

    test "resolves a pool-configured agent to one of the pool customers" do
      configure_pool!(["cus_pool_a", "cus_pool_b", "cus_pool_c"])

      result = PayerResolver.resolve(@task_run)
      assert_includes ["cus_pool_a", "cus_pool_b", "cus_pool_c"], result.payer_customer_id
    end

    test "pool selection is uniformly random across calls" do
      customers = ["cus_pool_a", "cus_pool_b", "cus_pool_c"]
      configure_pool!(customers)

      counts = Hash.new(0)
      300.times do
        counts[PayerResolver.resolve(@task_run).payer_customer_id] += 1
      end

      customers.each do |cus|
        # Expected 100 of 300 each; 60 is ~5 standard deviations below the
        # mean, so a false failure is vanishingly unlikely.
        assert_operator counts[cus], :>=, 60, "expected #{cus} to be picked roughly uniformly, got #{counts.inspect}"
      end
    end

    test "pool config takes precedence over a stamped billing customer" do
      billing_customer = StripeCustomer.create!(
        billable: @ai_agent,
        stripe_id: "cus_individual",
        active: true,
        pricing_plan_subscription_id: "bpps_test123",
      )
      @task_run.update!(stripe_customer_id: billing_customer.id)
      configure_pool!(["cus_pool_a"])

      result = PayerResolver.resolve(@task_run)
      assert_equal "cus_pool_a", result.payer_customer_id
    end

    test "falls back to the stamped billing customer when the agent is not in the pool config" do
      billing_customer = StripeCustomer.create!(
        billable: @ai_agent,
        stripe_id: "cus_individual",
        active: true,
        pricing_plan_subscription_id: "bpps_test123",
      )
      @task_run.update!(stripe_customer_id: billing_customer.id)
      configure_pool!(["cus_pool_a"], agent_id: "some-other-agent-id")

      result = PayerResolver.resolve(@task_run)
      assert_equal "cus_individual", result.payer_customer_id
    end

    test "raises not_a_billed_task when there is no pool config and no billing customer" do
      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "not_a_billed_task", error.code
    end

    test "malformed pool config is ignored" do
      ENV[PayerResolver::POOL_CONFIG_ENV] = "not valid json"

      error = assert_raises(PayerResolver::ResolutionError) do
        PayerResolver.resolve(@task_run)
      end
      assert_equal "not_a_billed_task", error.code
    end
  end
end
