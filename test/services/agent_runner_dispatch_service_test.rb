# typed: false
require "test_helper"

class AgentRunnerDispatchServiceTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    @tenant.enable_feature_flag!("ai_agents")
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

    chat_session = ChatSession.create!(
      tenant: @tenant,
      ai_agent: @ai_agent,
      initiated_by: @user,
    )
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

  test "fails task when stripe billing enabled but not active" do
    enable_stripe_billing_flag!(@tenant)

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal "failed", @task_run.status
    assert_includes @task_run.error, "Billing is not set up"
  end

  test "stamps stripe_customer_id when billing active" do
    enable_stripe_billing_flag!(@tenant)
    billing_customer = StripeCustomer.create!(
      billable: @ai_agent,
      stripe_id: "cus_test123",
      active: true,
    )
    @ai_agent.update!(stripe_customer_id: billing_customer.id)

    AgentRunnerDispatchService.dispatch(@task_run)

    @task_run.reload
    assert_equal billing_customer.id, @task_run.stripe_customer_id
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
    @tenant.disable_feature_flag!("ai_agents")

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

  def create_ai_agent
    ai_agent = User.create!(
      name: "Test Agent",
      email: "test-agent-#{SecureRandom.hex(4)}@not-real.com",
      user_type: "ai_agent",
      parent_id: @user.id,
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
end
