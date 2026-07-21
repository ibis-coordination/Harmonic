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
    @previous_agent_runner_secret = ENV.fetch("AGENT_RUNNER_SECRET", nil)
  end

  teardown do
    if @previous_agent_runner_secret.nil?
      ENV.delete("AGENT_RUNNER_SECRET")
    else
      ENV["AGENT_RUNNER_SECRET"] = @previous_agent_runner_secret
    end
  end

  test "dispatches task to Redis Stream" do
    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
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

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
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

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
    StripeService.stub :get_credit_balance, ->(_) { 500 } do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    @task_run.reload
    assert_not_equal "failed", @task_run.status, "free account with credits should dispatch: #{@task_run.error}"
    assert_equal billing_customer.id, @task_run.stripe_customer_id
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == @task_run.id }
    assert_not_nil entry, "free account with credits should reach the stream"
    assert_equal "stripe_gateway", entry[1]["llm_gateway_mode"]
    redis.close
  end

  test "falls back to the principal's customer when the agent record is unstamped" do
    # An agent created before its principal had a Stripe customer is never
    # stamped (assign_billing_customer! is a no-op and the subscription
    # checkout webhook only touches pending-flagged agents). The principal's
    # own customer funds it.
    enable_stripe_billing_flag!(@tenant)
    @user.update!(app_admin: true)
    parent_customer = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_parent_fallback",
      active: false,
      pricing_plan_subscription_id: "bpps_parent_fallback",
    )
    assert_nil @ai_agent.stripe_customer_id

    StripeService.stub :get_credit_balance, ->(_) { 500 } do
      AgentRunnerDispatchService.dispatch(@task_run)
    end

    @task_run.reload
    assert_not_equal "failed", @task_run.status, "unstamped agent of a funded principal should dispatch: #{@task_run.error}"
    assert_equal parent_customer.id, @task_run.stripe_customer_id
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

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
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

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
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

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
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

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
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

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
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

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
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

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
    redis.del("agent_tasks")

    AgentRunnerDispatchService.dispatch(@task_run)

    entries = redis.xrange("agent_tasks")
    assert_equal 0, entries.length
    redis.close
  end

  test "skips dispatch when ai_agents not enabled" do
    @tenant.disable_feature_flag!("internal_ai_agents")
    @tenant.disable_feature_flag!("external_ai_agents")

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
    redis.del("agent_tasks")

    AgentRunnerDispatchService.dispatch(@task_run)

    entries = redis.xrange("agent_tasks")
    assert_equal 0, entries.length
    redis.close
  end

  test "fails task when Redis XADD raises an error" do
    # Point at a bogus Redis to trigger connection failure
    original_url = ENV.fetch("REDIS_URL", nil)
    ENV["REDIS_URL"] = "redis://127.0.0.1:1/0"

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "dispatch_failed"
  ensure
    ENV["REDIS_URL"] = original_url
  end

  test "cleans up token when Redis XADD fails" do
    original_url = ENV.fetch("REDIS_URL", nil)
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

  # === System agents (the built-in personas) ===

  def create_trio_task_run!
    trio = PersonaSeeder.ensure_for(@collective, Personas::CADENCE)
    AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: trio, initiated_by: @user,
      task: "Where are my decisions?", max_steps: 10, status: "queued",
    )
  end

  test "trio routes through litellm when stripe_billing is off" do
    task_run = create_trio_task_run!

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
    AgentRunnerDispatchService.dispatch(task_run)

    task_run.reload
    assert_equal "queued", task_run.status, "dispatch should not fail: #{task_run.error}"
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == task_run.id }
    assert_not_nil entry
    assert_equal "litellm", entry[1]["llm_gateway_mode"]
    redis.close
  end

  test "trio on a billing tenant without a pool fails with an actionable message" do
    enable_stripe_billing_flag!(@tenant)
    task_run = create_trio_task_run!

    AgentRunnerDispatchService.dispatch(task_run)

    task_run.reload
    assert_equal "failed", task_run.status
    assert_match(/funding pool/, task_run.error)
  end

  test "a pool-funded trio routes through the stripe gateway without individual billing" do
    enable_stripe_billing_flag!(@tenant)
    task_run = create_trio_task_run!
    trio = T.must(task_run.ai_agent)
    # The test env's TRIO_DEFAULT_MODEL is a LiteLLM-only alias; a gateway
    # trio needs a gateway-resolvable model ("default" → DEFAULT_MODEL).
    trio.update!(agent_configuration: trio.agent_configuration.merge("model" => "default"))
    attach_funding_pool!(trio)

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
    # No individual billing exists; the pool funds it per call — a balance
    # preflight here would be a bug.
    StripeService.stub :get_credit_balance, ->(_) { raise "must not fetch balance for a pool-funded task" } do
      AgentRunnerDispatchService.dispatch(task_run)
    end

    task_run.reload
    assert_equal "queued", task_run.status, "pool-funded trio dispatch should not fail: #{task_run.error}"
    assert_nil task_run.stripe_customer_id, "pool-funded runs must not be stamped with an individual payer"
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == task_run.id }
    assert_not_nil entry
    assert_equal "stripe_gateway", entry[1]["llm_gateway_mode"]
    assert_equal StripeGatewayModelMapper::DEFAULT_MODEL, entry[1]["model"]
    redis.close
  end

  # === Workspace personas (owner-principaled system agents) ===

  def create_workspace_persona_task_run!
    workspace = T.must(@user.private_workspace)
    persona = PersonaSeeder.ensure_for(workspace, Personas::MELODY)
    # The test env's persona default model is a LiteLLM-only alias; a gateway
    # run needs a gateway-resolvable model ("default" → DEFAULT_MODEL).
    persona.update!(agent_configuration: persona.agent_configuration.merge("model" => "default"))
    AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: persona, initiated_by: @user,
      task: "Workspace task", max_steps: 10, status: "queued",
    )
  end

  test "a workspace persona on a billing tenant runs on the owner's billing" do
    # Workspaces can never open a funding pool (funding_pools_available?
    # requires standard?), so the pool fail-fast must not apply: the owner is
    # the principal and their billing pays, like any human-principaled agent.
    enable_stripe_billing_flag!(@tenant)
    task_run = create_workspace_persona_task_run!
    owner_customer = StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_owner_#{SecureRandom.hex(4)}",
      active: true,
      pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}",
    )

    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
    StripeService.stub :get_credit_balance, 500 do
      AgentRunnerDispatchService.dispatch(task_run)
    end

    task_run.reload
    assert_equal "queued", task_run.status, "owner-billed workspace persona dispatch should not fail: #{task_run.error}"
    assert_equal owner_customer.id, task_run.stripe_customer_id
    entry = redis.xrange("agent_tasks").find { |_id, fields| fields["task_run_id"] == task_run.id }
    assert_not_nil entry
    assert_equal "stripe_gateway", entry[1]["llm_gateway_mode"]
    redis.close
  end

  test "a workspace persona without owner billing fails with the billing message, not the pool message" do
    enable_stripe_billing_flag!(@tenant)
    task_run = create_workspace_persona_task_run!

    AgentRunnerDispatchService.dispatch(task_run)

    task_run.reload
    assert_equal "failed", task_run.status
    assert_match(/Billing is not set up/, task_run.error)
    assert_no_match(/funding pool/, task_run.error)
  end

  # === Pool-funded agents ===

  def attach_funding_pool!(agent)
    FeatureFlagService.config["funding_pools"] ||= {}
    FeatureFlagService.config["funding_pools"]["app_enabled"] = true
    @tenant.enable_feature_flag!("funding_pools")
    @collective.enable_feature_flag!("funding_pools")
    pool = FundingPool.create!(tenant: @tenant, collective: @collective, created_by: @user, member_draw_cap_cents: 500)
    # Enrollment requires the principal's own funded billing; the AGENT still
    # has no billing customer, which is the point of these tests.
    StripeCustomer.create!(
      billable: @user,
      stripe_id: "cus_principal_#{SecureRandom.hex(4)}",
      active: true,
      pricing_plan_subscription_id: "bpps_#{SecureRandom.hex(4)}",
    )
    pool.enroll!(@user, draw_cap_cents: 500)
    agent.update!(funding_pool: pool)
    pool
  end

  test "a chat turn for a pool-funded agent fails fast at dispatch" do
    # Pool funding doesn't cover private chat; failing here (not at the
    # first LLM call) puts a readable error in the chat UI immediately.
    enable_stripe_billing_flag!(@tenant)
    attach_funding_pool!(@ai_agent)
    @task_run.update!(mode: "chat_turn")

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_match(/pool funding doesn't cover private chat/i, @task_run.error)
  end

  test "dispatches a pool-funded agent with no individual billing through the gateway" do
    enable_stripe_billing_flag!(@tenant)
    attach_funding_pool!(@ai_agent)
    # No billing customer, no subscription, no balance — the pool funds it.
    # Neither the identity check nor the balance preflight applies, so a
    # balance fetch here would be a bug.
    redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
    StripeService.stub :get_credit_balance, ->(_) { raise "must not fetch balance for a pool-funded task" } do
      AgentRunnerDispatchService.dispatch(@task_run)
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

  test "agents without a funding pool still need individual billing" do
    enable_stripe_billing_flag!(@tenant)

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_match(/Billing is not set up/, @task_run.error)
  end

  # === Enabled-but-unfunded mention notification ===

  # A trio run as a mention produces it: triggered through an event-driven
  # automation rule, with the mentioner as the event actor.
  def create_unfunded_mention_run!(mentioner:)
    task_run = create_trio_task_run!
    event = Event.create!(tenant: @tenant, collective: @collective, event_type: "note.created", actor: mentioner)
    rule = AutomationRule.create!(
      tenant: @tenant, collective: @collective, name: "Cadence mention rule",
      trigger_type: "event", trigger_config: {}, actions: [], created_by: @user,
    )
    AutomationRuleRun.create!(
      tenant: @tenant, collective: @collective, automation_rule: rule,
      trigger_source: "event", status: "pending",
      triggered_by_event: event, ai_agent_task_run: task_run,
    )
    task_run
  end

  # The unfunded hint shares the persona_unavailable type with the
  # not-enabled hint; the pool-page URL is what distinguishes it.
  def unfunded_notifications_for(user)
    Notification.where(notification_type: "persona_unavailable", url: "#{@collective.path}/pool")
      .joins(:notification_recipients).where(notification_recipients: { user_id: user.id })
  end

  test "an unfunded mention notifies the mentioner with the pool link" do
    enable_stripe_billing_flag!(@tenant)
    task_run = create_unfunded_mention_run!(mentioner: @user)

    AgentRunnerDispatchService.dispatch(task_run)

    assert_equal "failed", task_run.reload.status
    notification = unfunded_notifications_for(@user).first
    assert notification, "the mentioner should be told why nothing happened"
    assert_equal "#{@collective.path}/pool", notification.url
    assert_match(/funding pool/i, notification.body)
  end

  test "a second unfunded mention does not re-notify" do
    enable_stripe_billing_flag!(@tenant)

    AgentRunnerDispatchService.dispatch(create_unfunded_mention_run!(mentioner: @user))
    AgentRunnerDispatchService.dispatch(create_unfunded_mention_run!(mentioner: @user))

    assert_equal 1, unfunded_notifications_for(@user).count
  end

  test "different mentioners are each notified once" do
    enable_stripe_billing_flag!(@tenant)
    other = create_user(name: "Other Mentioner")
    @tenant.add_user!(other)
    @collective.add_user!(other)

    AgentRunnerDispatchService.dispatch(create_unfunded_mention_run!(mentioner: @user))
    AgentRunnerDispatchService.dispatch(create_unfunded_mention_run!(mentioner: other))

    assert_equal 1, unfunded_notifications_for(@user).count
    assert_equal 1, unfunded_notifications_for(other).count
  end

  test "the notification re-arms after a pool was opened and later closed" do
    enable_stripe_billing_flag!(@tenant)
    AgentRunnerDispatchService.dispatch(create_unfunded_mention_run!(mentioner: @user))
    assert_equal 1, unfunded_notifications_for(@user).count

    # A pool opened and then closed marks a new unfunded spell.
    FundingPool.create!(
      tenant: @tenant, collective: @collective, created_by: @user,
      member_draw_cap_cents: 500, archived_at: Time.current,
    )

    AgentRunnerDispatchService.dispatch(create_unfunded_mention_run!(mentioner: @user))

    assert_equal 2, unfunded_notifications_for(@user).count
  end

  test "a prior not-enabled hint does not suppress the unfunded hint" do
    enable_stripe_billing_flag!(@tenant)
    # The not-enabled variant of the same notification type links settings,
    # not the pool page.
    earlier_event = Event.create!(tenant: @tenant, collective: @collective, event_type: "note.created", actor: @user)
    NotificationService.create_and_deliver!(
      event: earlier_event,
      recipient: @user,
      notification_type: "persona_unavailable",
      title: "@cadence isn't enabled in #{@collective.name}",
      url: "#{@collective.path}/settings",
    )

    AgentRunnerDispatchService.dispatch(create_unfunded_mention_run!(mentioner: @user))

    assert_equal 1, unfunded_notifications_for(@user).count
  end

  test "a manually-triggered unfunded run does not notify" do
    enable_stripe_billing_flag!(@tenant)
    task_run = create_trio_task_run!

    AgentRunnerDispatchService.dispatch(task_run)

    assert_equal "failed", task_run.reload.status
    assert_equal 0, unfunded_notifications_for(@user).count
  end
end
