# typed: false
require "test_helper"

class AgentRunnerDispatchServiceTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("internal_ai_agents")
    @tenant.enable_feature_flag!("external_ai_agents")
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    @ai_agent = create_ai_agent
    @task_run = AiAgentTaskRun.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
      task: "Test task",
      max_steps: 10,
      status: "queued",
    )

    # Save the default set by test_helper so we can restore it; any test that
    # overrides AGENT_RUNNER_SECRET must restore this value, not delete the key.
    @previous_agent_runner_secret = ENV["AGENT_RUNNER_SECRET"]
  end

  teardown do
    if @previous_agent_runner_secret.nil?
      ENV.delete("AGENT_RUNNER_SECRET")
    else
      ENV["AGENT_RUNNER_SECRET"] = @previous_agent_runner_secret
    end
  end

  test "dispatches task to Redis Stream" do
    redis = Redis.new(url: ENV["REDIS_URL"])
    AgentRunnerDispatchService.dispatch(@task_run)

    # Don't assume an empty stream — other tests may share this Redis instance.
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_not_nil entry, "task run should have been added to the stream"
    fields = entry[1]
    assert_equal "Test task", fields["task"]
    assert_equal @ai_agent.id, fields["agent_id"]
    assert_equal @tenant.subdomain, fields["tenant_subdomain"]
    assert fields["encrypted_token"].present?, "encrypted_token should be in stream payload"

    redis.close
  end

  test "creates ephemeral token linked to task run" do
    AgentRunnerDispatchService.dispatch(@task_run)

    token = ApiToken.unscope(where: :internal).find_by(context_type: "AiAgentTaskRun", context_id: @task_run.id)
    assert_not_nil token
    assert token.internal?
    assert_equal @ai_agent.id, token.user_id
    assert_equal @tenant.id, token.tenant_id
  end

  test "encrypted token in stream can be decrypted" do
    ENV["AGENT_RUNNER_SECRET"] = "test-secret-for-crypto"

    redis = Redis.new(url: ENV["REDIS_URL"])
    AgentRunnerDispatchService.dispatch(@task_run)

    # Find the specific entry for this task_run (the stream may carry entries
    # from other tests that ran under a different AGENT_RUNNER_SECRET).
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_not_nil entry, "task run should have been added to the stream"
    encrypted = entry[1]["encrypted_token"]
    decrypted = AgentRunnerCrypto.decrypt(encrypted)

    # Should be a valid 40-char hex token
    assert_match(/\A[a-f0-9]{40}\z/, decrypted)

    redis.close
    # teardown restores the secret to the test_helper default
  end

  test "fails task for suspended agent" do
    @ai_agent.update!(suspended_at: Time.current)

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "suspended"
  end

  test "fails task for archived agent" do
    tu = @ai_agent.tenant_users.find_by(tenant_id: @tenant.id)
    tu.update!(archived_at: Time.current)

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "deactivated"
  end

  test "fails task for agent pending billing setup" do
    @ai_agent.update!(pending_billing_setup: true)

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "pending billing setup"
  end

  test "broadcasts error to chat session when dispatch fails for chat_turn" do
    @ai_agent.update!(pending_billing_setup: true)

    chat_session = ChatSession.find_or_create_between(user_a: @ai_agent, user_b: @user, tenant: @tenant)
    @task_run.update!(mode: "chat_turn", chat_session: chat_session)

    stream = ChatSessionChannel.broadcasting_for(chat_session)

    assert_broadcast_on(stream, {
      "type" => "status",
      "status" => "error",
      "error" => "Agent is pending billing setup. Set up billing at /billing to activate this agent.",
      "task_run_id" => @task_run.id,
    }) do
      AgentRunnerDispatchService.dispatch(@task_run)
    end
  end

  test "does not broadcast when regular task dispatch fails" do
    @ai_agent.update!(pending_billing_setup: true)

    # No chat session, regular task mode
    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    # No error raised = no broadcast attempted for non-chat task
  end

  test "fails task when stripe billing enabled but identity is not paid for" do
    # Normal (non-exempt) principal with no active subscription: the per-identity
    # fee is unpaid, so the identity gate (a) fails. This is the norm.
    enable_stripe_billing_flag!(@tenant)

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "Billing is not set up"
  end

  test "fails a free-account principal that has no prepaid credits" do
    # A free-account principal (app admin — nothing billable) clears the
    # identity gate (a), but agent usage is still funded by prepaid credits, so
    # with no pricing-plan subscription the credit gate (b) fails.
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)
    billing_customer = StripeCustomer.create!(
      billable: @ai_agent,
      stripe_id: "cus_free_nocredits",
      active: false,
      pricing_plan_subscription_id: nil,
    )
    @ai_agent.update!(stripe_customer_id: billing_customer.id)

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "AI usage billing is not set up"
  end

  test "dispatches for a free-account principal that has prepaid AI credits" do
    # Regression for #450: a free account (an app admin — nothing billable, so
    # no per-identity subscription and active? is legitimately false) that has
    # bought LLM credits sets up the metered pricing-plan subscription, which is
    # what funds agent usage. The per-identity subscription is a separate
    # concern and must not gate dispatch for such an exempt principal.
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)
    billing_customer = StripeCustomer.create!(
      billable: @ai_agent,
      stripe_id: "cus_free123",
      active: false,
      pricing_plan_subscription_id: "bpps_free123",
    )
    @ai_agent.update!(stripe_customer_id: billing_customer.id)

    redis = Redis.new(url: ENV["REDIS_URL"])
    StripeService.stub :get_credit_balance, ->(_) { 500 } do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    @task_run.reload
    refute_equal "failed", @task_run.status, "free account with credits should dispatch: #{@task_run.error}"
    assert_equal billing_customer.id, @task_run.stripe_customer_id
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_not_nil entry, "free account with credits should reach the stream"
    assert_equal "stripe_gateway", entry[1]["llm_gateway_mode"]
    redis.close
  end

  test "stamps stripe_customer_id when billing active" do
    setup_active_billing!

    StripeService.stub :get_credit_balance, ->(_) { 500 } do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    @task_run.reload
    assert_equal @ai_agent.billing_customer.id, @task_run.stripe_customer_id
  end

  # === Per-task gateway routing ===

  test "publishes stripe_gateway mode with mapped model when billing active" do
    setup_active_billing!
    @ai_agent.update!(agent_configuration: { "mode" => "internal", "model" => "anthropic/claude-sonnet-4.6" })

    redis = Redis.new(url: ENV["REDIS_URL"])
    StripeService.stub :get_credit_balance, ->(_) { 500 } do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_not_nil entry, "task should be dispatched: #{@task_run.reload.error}"
    fields = entry[1]
    assert_equal "stripe_gateway", fields["llm_gateway_mode"]
    assert_equal "anthropic/claude-sonnet-4.6", fields["model"]
    # Customer ids no longer ride the stream; the gateway resolves the payer from the task run.
    assert_nil fields["stripe_customer_stripe_id"]
    redis.close
  end

  test "publishes stripe_gateway mode with default model when agent has none configured" do
    setup_active_billing!

    redis = Redis.new(url: ENV["REDIS_URL"])
    StripeService.stub :get_credit_balance, ->(_) { 500 } do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_not_nil entry, "task should be dispatched: #{@task_run.reload.error}"
    assert_equal StripeGatewayModelMapper::DEFAULT_MODEL, entry[1]["model"]
    redis.close
  end

  test "publishes litellm mode with unmapped model when stripe_billing is off" do
    @ai_agent.update!(agent_configuration: { "mode" => "internal", "model" => "anthropic/claude-sonnet-4.6" })

    redis = Redis.new(url: ENV["REDIS_URL"])
    AgentRunnerDispatchService.dispatch(@task_run)

    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_not_nil entry
    fields = entry[1]
    assert_equal "litellm", fields["llm_gateway_mode"]
    assert_equal "anthropic/claude-sonnet-4.6", fields["model"]
    redis.close
  end

  test "fails task when agent model cannot be mapped for the gateway" do
    setup_active_billing!
    @ai_agent.update!(agent_configuration: { "mode" => "internal", "model" => "llama3" })

    redis = Redis.new(url: ENV["REDIS_URL"])
    StripeService.stub :get_credit_balance, ->(_) { 500 } do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "llama3"
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_nil entry, "unmappable task must not reach the stream"
    redis.close
  end

  test "fails task when billing customer has no pricing plan subscription" do
    setup_active_billing!(pricing_plan_subscription_id: nil)

    redis = Redis.new(url: ENV["REDIS_URL"])
    StripeService.stub :get_credit_balance, ->(_) { 500 } do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "usage billing"
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_nil entry, "task without usage billing must not reach the stream"
    redis.close
  end

  test "fails task when credit balance is zero" do
    setup_active_billing!

    StripeService.stub :get_credit_balance, ->(_) { 0 } do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "Insufficient credit balance"
  end

  test "fails task for external agent" do
    external_agent = create_ai_agent(mode: "external")
    assert external_agent.external_ai_agent?, "precondition: agent should be external"

    task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: external_agent, initiated_by: @user,
      task: "Test task", max_steps: 10, status: "queued",
    )

    AgentRunnerDispatchService.dispatch(task_run)

    task_run.reload
    assert_equal "failed", task_run.status
    assert_includes task_run.error, "external"
  end

  test "dispatches task for internal agent" do
    assert @ai_agent.internal_ai_agent?, "precondition: agent should be internal"

    redis = Redis.new(url: ENV["REDIS_URL"])
    AgentRunnerDispatchService.dispatch(@task_run)

    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_not_nil entry, "internal agent task should be dispatched"
    redis.close
  end

  test "skips dispatch for non-ai-agent user" do
    regular_user = User.create!(
      name: "Regular User",
      email: "regular-#{SecureRandom.hex(4)}@example.com",
    )
    @task_run.update_columns(ai_agent_id: regular_user.id)
    @task_run.reload

    redis = Redis.new(url: ENV["REDIS_URL"])
    redis.del("agent_tasks")

    AgentRunnerDispatchService.dispatch(@task_run)

    entries = redis.xrange("agent_tasks")
    assert_equal 0, entries.length
    redis.close
  end

  test "skips dispatch when ai_agents not enabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @tenant.disable_feature_flag!("external_ai_agents")

    redis = Redis.new(url: ENV["REDIS_URL"])
    redis.del("agent_tasks")

    AgentRunnerDispatchService.dispatch(@task_run)

    entries = redis.xrange("agent_tasks")
    assert_equal 0, entries.length
    redis.close
  end

  test "fails task when Redis XADD raises an error" do
    # Point at a bogus Redis to trigger connection failure
    original_url = ENV["REDIS_URL"]
    ENV["REDIS_URL"] = "redis://127.0.0.1:1/0"

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "dispatch_failed"
  ensure
    ENV["REDIS_URL"] = original_url
  end

  test "cleans up token when Redis XADD fails" do
    original_url = ENV["REDIS_URL"]
    ENV["REDIS_URL"] = "redis://127.0.0.1:1/0"

    AgentRunnerDispatchService.dispatch(@task_run)

    token = ApiToken.unscope(where: :internal).find_by(context_type: "AiAgentTaskRun", context_id: @task_run.id)
    assert_nil token, "ephemeral token should be destroyed after dispatch failure"
  ensure
    ENV["REDIS_URL"] = original_url
  end

  private

  def create_ai_agent(mode: "internal")
    ai_agent = User.create!(
      name: "Test Agent #{SecureRandom.hex(4)}",
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: @user.id,
      agent_configuration: { "mode" => mode },
    )
    tu = @tenant.add_user!(ai_agent)
    ai_agent.tenant_user = tu
    CollectiveMember.create!(collective: @collective, user: ai_agent)
    ai_agent
  end

  def enable_stripe_billing_flag!(tenant)
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    tenant.enable_feature_flag!("stripe_billing")
  end

  def setup_active_billing!(pricing_plan_subscription_id: "bpps_test123")
    enable_stripe_billing_flag!(@tenant)
    billing_customer = StripeCustomer.create!(
      billable: @ai_agent,
      stripe_id: "cus_test123",
      active: true,
      pricing_plan_subscription_id: pricing_plan_subscription_id,
    )
    @ai_agent.update!(stripe_customer_id: billing_customer.id)
  end

  # === System agent (Trio) billing exemption ===

  test "dispatches task for system agent without billing setup" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.create_main_collective!(created_by: @user)
    trio = TrioSeeder.ensure_for(T.must(@tenant.main_collective))
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: trio, initiated_by: @user,
      task: "Where are my decisions?", max_steps: 10, status: "queued",
    )

    redis = Redis.new(url: ENV["REDIS_URL"])
    AgentRunnerDispatchService.dispatch(task_run)

    task_run.reload
    assert_equal "queued", task_run.status, "system agent dispatch should not fail: #{task_run.error}"
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == task_run.id }
    assert_not_nil entry, "system agent task should be dispatched to the stream"
    assert_nil entry[1]["stripe_customer_stripe_id"]
    redis.close
  end

  test "does not stamp stripe_customer_id on system agent task run" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.create_main_collective!(created_by: @user)
    trio = TrioSeeder.ensure_for(T.must(@tenant.main_collective))
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: trio, initiated_by: @user,
      task: "Hello", max_steps: 10, status: "queued",
    )

    AgentRunnerDispatchService.dispatch(task_run)

    task_run.reload
    assert_equal "queued", task_run.status, "dispatch must succeed: #{task_run.error}"
    assert_nil task_run.stripe_customer_id
  end

  test "system agent routes through litellm and skips credit balance check" do
    enable_stripe_billing_flag!(@tenant)
    @tenant.create_main_collective!(created_by: @user)
    trio = TrioSeeder.ensure_for(T.must(@tenant.main_collective))
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: trio, initiated_by: @user,
      task: "Hello", max_steps: 10, status: "queued",
    )

    redis = Redis.new(url: ENV["REDIS_URL"])
    # StripeService.get_credit_balance must not be called for system agents.
    # If it were, this stub would raise.
    StripeService.stub :get_credit_balance, ->(_) { raise "should not be called for system agent" } do
      AgentRunnerDispatchService.dispatch(task_run)
    end

    task_run.reload
    assert_equal "queued", task_run.status
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == task_run.id }
    assert_not_nil entry
    assert_equal "litellm", entry[1]["llm_gateway_mode"]
    redis.close
  end

  # === Pool-configured agents (LLM_POOL_CONFIG proof of concept) ===

  def with_pool_config(customer_ids, agent_id:)
    previous = ENV.fetch(LLMGateway::PayerResolver::POOL_CONFIG_ENV, nil)
    ENV[LLMGateway::PayerResolver::POOL_CONFIG_ENV] = { agent_id => customer_ids }.to_json
    yield
  ensure
    if previous.nil?
      ENV.delete(LLMGateway::PayerResolver::POOL_CONFIG_ENV)
    else
      ENV[LLMGateway::PayerResolver::POOL_CONFIG_ENV] = previous
    end
  end

  test "dispatches a pool-configured agent with no individual billing through the gateway" do
    enable_stripe_billing_flag!(@tenant)
    # No billing customer, no subscription, no balance — the pool funds it.
    # Neither the identity check nor the balance preflight applies, so a
    # balance fetch here would be a bug.
    redis = Redis.new(url: ENV["REDIS_URL"])
    StripeService.stub :get_credit_balance, ->(_) { raise "must not fetch balance for a pool-funded task" } do
      with_pool_config(["cus_pool_a", "cus_pool_b"], agent_id: @ai_agent.id) do
        AgentRunnerDispatchService.dispatch(@task_run)
      end
    end

    @task_run.reload
    assert_equal "queued", @task_run.status, "pool-funded dispatch should not fail: #{@task_run.error}"
    assert_nil @task_run.stripe_customer_id, "pool-funded runs must not be stamped with an individual payer"

    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_not_nil entry, "pool-funded task should be dispatched to the stream"
    assert_equal "stripe_gateway", entry[1]["llm_gateway_mode"]
    assert_equal StripeGatewayModelMapper::DEFAULT_MODEL, entry[1]["model"]
    redis.close
  end

  test "pool config does not apply to agents outside it" do
    enable_stripe_billing_flag!(@tenant)

    with_pool_config(["cus_pool_a"], agent_id: "some-other-agent") do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_match(/Billing is not set up/, @task_run.error)
  end
end
