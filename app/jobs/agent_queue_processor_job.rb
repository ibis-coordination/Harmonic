# typed: true
# frozen_string_literal: true

class AgentQueueProcessorJob < TenantScopedJob
  extend T::Sig

  queue_as :default

  # Allow injecting a mock navigator class for testing
  class_attribute :navigator_class, default: AgentNavigator

  # Tasks running longer than this are considered stuck and will be marked as failed
  STUCK_TASK_TIMEOUT = 15.minutes

  sig { params(ai_agent_id: String, tenant_id: String).void }
  def perform(ai_agent_id:, tenant_id:)
    tenant = Tenant.find_by(id: tenant_id)
    ai_agent = User.find_by(id: ai_agent_id)

    return unless tenant && ai_agent
    return unless ai_agent.ai_agent?
    return unless tenant.ai_agents_enabled?

    # Set tenant context for querying AiAgentTaskRun
    set_tenant_context!(tenant)

    task_run = claim_next_task(ai_agent, tenant)
    return unless task_run

    # Set additional context for this specific task run
    set_task_run_context!(task_run)

    collective = resolve_collective(task_run)
    set_collective_context!(collective) if collective

    begin
      run_task(task_run)
    ensure
      # Schedule next task (context will be cleared/restored by middleware)
      schedule_next_task(ai_agent_id, tenant_id)
    end
  end

  private

  sig { params(ai_agent: User, tenant: Tenant).returns(T.nilable(AiAgentTaskRun)) }
  def claim_next_task(ai_agent, tenant)
    claimed_task = T.let(nil, T.nilable(AiAgentTaskRun))

    ai_agent.with_lock do
      # Check for stuck tasks first - recover before checking if something is running
      recover_stuck_tasks(ai_agent, tenant)

      # Already running? Exit - the running job will trigger us when done
      next if AiAgentTaskRun.exists?(ai_agent: ai_agent, tenant: tenant, status: "running")

      # Get oldest queued task
      next_task = AiAgentTaskRun
        .where(ai_agent: ai_agent, tenant: tenant, status: "queued")
        .order(:created_at)
        .first

      next unless next_task

      # Claim it
      next_task.update!(status: "running", started_at: Time.current)
      claimed_task = next_task
    end

    claimed_task
  end

  sig { params(ai_agent: User, tenant: Tenant).void }
  def recover_stuck_tasks(ai_agent, tenant)
    stuck_tasks = AiAgentTaskRun
      .where(ai_agent: ai_agent, tenant: tenant, status: "running")
      .where("started_at < ?", STUCK_TASK_TIMEOUT.ago)

    stuck_tasks.find_each do |task|
      Rails.logger.warn(
        "[AgentQueueProcessorJob] Recovering stuck task " \
        "id=#{task.id} ai_agent_id=#{ai_agent.id} " \
        "started_at=#{task.started_at} duration=#{Time.current - task.started_at}s"
      )

      task.update!(
        status: "failed",
        success: false,
        error: "Task timed out after #{STUCK_TASK_TIMEOUT.inspect} - job may have crashed or been killed",
        completed_at: Time.current
      )
      # Notify any parent automation runs
      task.notify_parent_automation_runs!
    end
  end

  sig { params(task_run: AiAgentTaskRun).void }
  def run_task(task_run)
    ai_agent = T.must(task_run.ai_agent)

    # Agent must be active (not archived, suspended, or pending billing)
    agent_tenant_user = ai_agent.tenant_users.find_by(tenant_id: task_run.tenant_id)
    agent_archived = agent_tenant_user&.archived? || false
    if ai_agent.suspended? || agent_archived || ai_agent.pending_billing_setup?
      status_msg = if ai_agent.pending_billing_setup?
        "pending billing setup. Set up billing at /billing to activate this agent"
      elsif ai_agent.suspended?
        "suspended"
      else
        "deactivated"
      end
      task_run.update!(
        status: "failed",
        success: false,
        error: "Agent is #{status_msg}.",
        completed_at: Time.current,
      )
      task_run.notify_parent_automation_runs!
      return
    end

    billing_customer = ai_agent.billing_customer

    # Billing gate: if stripe_billing is enabled, agent must have active billing
    if T.must(task_run.tenant).feature_enabled?("stripe_billing")
      unless billing_customer&.active?
        task_run.update!(
          status: "failed",
          success: false,
          error: "Billing is not set up. Please set up billing at /billing before running AI agents.",
          completed_at: Time.current,
        )
        task_run.notify_parent_automation_runs!
        return
      end

      # Stamp immutable billing attribution on the run
      task_run.update!(stripe_customer_id: billing_customer.id)

      # Pre-flight credit balance check (best-effort — gateway 402 is authoritative)
      if ENV.fetch("LLM_GATEWAY_MODE", "litellm") == "stripe_gateway"
        credit_balance = StripeService.get_credit_balance(billing_customer)
        if credit_balance == 0
          task_run.update!(
            status: "failed",
            success: false,
            error: "Insufficient credit balance. Add funds at /billing before running agents.",
            completed_at: Time.current,
          )
          task_run.notify_parent_automation_runs!
          return
        end
      end
    end

    # Resolve the Stripe cus_xxx ID for the gateway (nil in litellm mode)
    stripe_customer_stripe_id = billing_customer&.stripe_id

    navigator = self.class.navigator_class.new(
      user: ai_agent,
      tenant: task_run.tenant,
      collective: resolve_collective(task_run),
      model: task_run.model,
      stripe_customer_id: stripe_customer_stripe_id,
    )

    result = navigator.run(task: task_run.task, max_steps: task_run.max_steps)

    # Skip local cost estimation when Stripe gateway handles billing
    stripe_gateway_active = ENV.fetch("LLM_GATEWAY_MODE", "litellm") == "stripe_gateway"
    estimated_cost = if stripe_gateway_active
                       nil
                     else
                       LLMPricing.calculate_cost(
                         model: task_run.model || "default",
                         input_tokens: result.input_tokens,
                         output_tokens: result.output_tokens,
                       )
                     end

    task_run.update!(
      status: result.success ? "completed" : "failed",
      success: result.success,
      final_message: result.final_message,
      error: result.error,
      steps_count: result.steps.count,
      steps_data: result.steps.map { |s| { type: s.type, detail: s.detail, timestamp: s.timestamp.iso8601 } },
      completed_at: Time.current,
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
      total_tokens: result.input_tokens + result.output_tokens,
      estimated_cost_usd: estimated_cost,
    )

    # Notify any parent automation runs that this task has finished
    task_run.notify_parent_automation_runs!
  end

  sig { params(task_run: AiAgentTaskRun).returns(T.nilable(Collective)) }
  def resolve_collective(task_run)
    # Extract collective from task path if possible, or use first available
    T.must(task_run.ai_agent).collective_members.first&.collective
  end

  sig { params(ai_agent_id: String, tenant_id: String).void }
  def schedule_next_task(ai_agent_id, tenant_id)
    AgentQueueProcessorJob.perform_later(ai_agent_id: ai_agent_id, tenant_id: tenant_id)
  end
end
