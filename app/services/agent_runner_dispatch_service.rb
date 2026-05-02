# typed: true
# frozen_string_literal: true

# Dispatches AI agent task runs to the agent-runner service via Redis Streams.
# Performs all validation and billing checks before publishing to the stream.
class AgentRunnerDispatchService
  extend T::Sig

  STREAM_NAME = "agent_tasks"

  sig { params(task_run: AiAgentTaskRun).void }
  def self.dispatch(task_run)
    new(task_run).dispatch
  end

  sig { params(task_run: AiAgentTaskRun).void }
  def initialize(task_run)
    @task_run = task_run
  end

  sig { void }
  def dispatch
    ai_agent = @task_run.ai_agent
    tenant = @task_run.tenant

    # Precondition checks
    return unless ai_agent&.ai_agent?
    return unless tenant&.ai_agents_enabled?

    # Only dispatch tasks that are still queued. Guards against a race where
    # the rake `agent_runner:redispatch_queued` task enumerates queued runs
    # and then the runner picks one up before dispatch reaches it — without
    # this guard, any downstream fail_task! would clobber the running state.
    return unless @task_run.status == "queued"

    # External agents use API tokens, not the agent-runner
    if ai_agent.external_ai_agent?
      fail_task!("Cannot dispatch tasks for external agents. External agents interact via API tokens, not the agent-runner.")
      return
    end

    # Agent status checks
    agent_tenant_user = ai_agent.tenant_users.find_by(tenant_id: tenant.id)
    agent_archived = agent_tenant_user&.archived? || false
    if ai_agent.suspended? || agent_archived || ai_agent.pending_billing_setup?
      status_msg = if ai_agent.pending_billing_setup?
        "pending billing setup. Set up billing at /billing to activate this agent"
      elsif ai_agent.suspended?
        "suspended"
      else
        "deactivated"
      end
      fail_task!("Agent is #{status_msg}.")
      return
    end

    # Billing checks
    billing_customer = ai_agent.billing_customer
    if tenant.feature_enabled?("stripe_billing")
      unless billing_customer&.active?
        fail_task!("Billing is not set up. Please set up billing at /billing before running AI agents.")
        return
      end

      # Stamp immutable billing attribution
      @task_run.update!(stripe_customer_id: billing_customer.id)

      # Pre-flight credit balance check
      if ENV.fetch("LLM_GATEWAY_MODE", "litellm") == "stripe_gateway"
        credit_balance = StripeService.get_credit_balance(billing_customer)
        if credit_balance.nil? || credit_balance <= 0
          fail_task!("Insufficient credit balance. Add funds at /billing before running agents.")
          return
        end
      end
    end

    # Create ephemeral token linked to task run.
    # Extended TTL (4 hours) because the token is created at dispatch time,
    # not execution time — the task may sit in the queue before agent-runner picks it up.
    token = ApiToken.create_internal_token(
      user: ai_agent,
      tenant: tenant,
      context: @task_run,
      expires_in: 4.hours,
    )

    # Publish to Redis Stream with encrypted token
    begin
      publish_to_stream(token, billing_customer)
    rescue StandardError => e
      # Redis failure after token creation — clean up the token and fail the task
      # so it shows up on the admin page instead of lurking as "queued" forever.
      token.destroy
      fail_task!("dispatch_failed: #{e.message}")
      Rails.logger.error("[AgentRunnerDispatchService] Redis publish failed for task #{@task_run.id}: #{e.message}")
    end
  end

  private

  sig { params(error: String).void }
  def fail_task!(error)
    # Double-check state at mutation time — the task could have been picked up
    # between the `status == "queued"` guard in `dispatch` and here. Only
    # transition from queued; leave running/terminal states alone.
    return unless @task_run.status == "queued"

    @task_run.update!(
      status: "failed",
      success: false,
      error: error,
      completed_at: Time.current,
    )
    broadcast_chat_error(error)
    @task_run.notify_parent_automation_runs!
  end

  sig { params(error: String).void }
  def broadcast_chat_error(error)
    return unless @task_run.mode == "chat_turn"

    chat_session = @task_run.chat_session
    return unless chat_session

    ChatSessionChannel.broadcast_to(
      chat_session,
      { type: "status", status: "error", error: error, task_run_id: @task_run.id },
    )
  rescue StandardError => e
    Rails.logger.error("[AgentRunnerDispatchService] Failed to broadcast chat error: #{e.message}")
  end

  sig { params(token: ApiToken, billing_customer: T.nilable(StripeCustomer)).void }
  def publish_to_stream(token, billing_customer)
    encrypted_token = AgentRunnerCrypto.encrypt(token.plaintext_token)

    redis = Redis.new(url: ENV["REDIS_URL"])
    payload = {
      task_run_id: @task_run.id,
      encrypted_token: encrypted_token,
      task: @task_run.task,
      max_steps: @task_run.max_steps.to_s,
      model: T.must(@task_run.ai_agent).agent_configuration&.dig("model") || "",
      agent_id: T.must(@task_run.ai_agent).id,
      tenant_subdomain: T.must(@task_run.tenant).subdomain,
      stripe_customer_stripe_id: billing_customer&.stripe_id || "",
      mode: @task_run.mode,
      chat_session_id: @task_run.chat_session_id || "",
    }
    redis.xadd(STREAM_NAME, payload, maxlen: 10_000, approximate: true)
  ensure
    redis&.close
  end
end
