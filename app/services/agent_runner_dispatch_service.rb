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
    return unless tenant&.internal_ai_agents_enabled?

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

    # Billing checks. System agents (e.g., Trio) are exempt: they have no
    # billing_customer, are never charged, and the agent-runner already
    # tolerates a missing stripe_customer_stripe_id by skipping the
    # X-Stripe-Customer-ID header.
    billing_customer = ai_agent.billing_customer
    if tenant.feature_enabled?("stripe_billing") && !ai_agent.system?
      # (a) The agent's identity must be paid for before we run a task — the
      # norm, unchanged. An agent's billing_customer is its principal's Stripe
      # customer (see AiAgentsController#assign_billing_customer!), so an active
      # billing_customer means the principal holds an active per-identity
      # subscription.
      #
      # The one exception is a free-account principal: a principal with nothing
      # billable (e.g. an app admin, or all resources billing-exempt) owes no
      # per-identity fee and so never opens a subscription — active? is
      # legitimately false. It is a special case, not the norm; billable_quantity
      # of zero is exactly "nothing to bill". Such an account still needs prepaid
      # credits to actually run — enforced in (b) below — so the exemption only
      # waives the per-identity fee.
      unless billing_customer&.active? || ai_agent.parent&.billable_quantity&.zero?
        fail_task!("Billing is not set up. Please set up billing at /billing before running AI agents.")
        return
      end

      # Stamp immutable billing attribution
      @task_run.update!(stripe_customer_id: billing_customer.id) if billing_customer
    end

    # Gateway routing is decided per task: a billed agent (stripe_billing tenant,
    # non-system) meters its tokens against prepaid credits and so goes through
    # the Stripe AI Gateway; everyone else (system agents, non-billing tenants)
    # goes through LiteLLM. The runner reads this from the stream payload rather
    # than its own env config. Routing does not depend on the per-identity
    # subscription: a free account with credits still drains them via the gateway.
    gateway_mode = if tenant.feature_enabled?("stripe_billing") && !ai_agent.system?
      "stripe_gateway"
    else
      "litellm"
    end

    model = ai_agent.agent_configuration&.dig("model") || ""
    if gateway_mode == "stripe_gateway"
      # (b) LLM usage must be funded: a prepaid-credit (pricing-plan) subscription
      # exists and has a positive balance. Required for every billed agent —
      # free-account or paying alike. Topping up at /billing creates the
      # subscription; without it, gateway usage would meter but never bill.
      if billing_customer.nil? || billing_customer.pricing_plan_subscription_id.blank?
        fail_task!("AI usage billing is not set up. Add credits at /billing before running AI agents.")
        return
      end

      # Pre-flight credit balance check
      credit_balance = StripeService.get_credit_balance(T.must(billing_customer))
      if credit_balance.nil? || credit_balance <= 0
        fail_task!("Insufficient credit balance. Add funds at /billing before running agents.")
        return
      end

      begin
        model = StripeGatewayModelMapper.map(model)
      rescue StripeGatewayModelMapper::UnmappedModelError => e
        fail_task!(e.message)
        return
      end
    end

    # Create ephemeral token linked to task run.
    # Extended TTL (4 hours) because the token is created at dispatch time,
    # not execution time — the task may sit in the queue before agent-runner picks it up.
    # mcp_only: true locks the token to /mcp. All agent-acting calls from the
    # runner go through McpClient → /mcp, so this closes the audit-bypass hole
    # where a leaked token could be used against direct REST/markdown
    # endpoints without producing an McpToolCallLog row.
    token = ApiToken.create_internal_token(
      user: ai_agent,
      tenant: tenant,
      context: @task_run,
      expires_in: 4.hours,
      mcp_only: true,
    )

    # Publish to Redis Stream with encrypted token
    begin
      publish_to_stream(token, billing_customer, model: model, gateway_mode: gateway_mode)
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

  sig { params(token: ApiToken, billing_customer: T.nilable(StripeCustomer), model: String, gateway_mode: String).void }
  def publish_to_stream(token, billing_customer, model:, gateway_mode:)
    encrypted_token = AgentRunnerCrypto.encrypt(token.plaintext_token)

    redis = Redis.new(url: ENV["REDIS_URL"])
    payload = {
      task_run_id: @task_run.id,
      encrypted_token: encrypted_token,
      task: @task_run.task,
      max_steps: @task_run.max_steps.to_s,
      model: model,
      llm_gateway_mode: gateway_mode,
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
