# typed: true

class AgentQueueProcessorJob < ApplicationJob
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

    task_run = claim_next_task(ai_agent, tenant)
    return unless task_run

    set_context(tenant, task_run)

    begin
      run_task(task_run)
    ensure
      restore_context
      # Check for more queued tasks
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
    end
  end

  sig { params(task_run: AiAgentTaskRun).void }
  def run_task(task_run)
    navigator = self.class.navigator_class.new(
      user: task_run.ai_agent,
      tenant: task_run.tenant,
      superagent: resolve_superagent(task_run),
      model: task_run.model
    )

    result = navigator.run(task: task_run.task, max_steps: task_run.max_steps)

    estimated_cost = LLMPricing.calculate_cost(
      model: task_run.model || "default",
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens
    )

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
      estimated_cost_usd: estimated_cost
    )
  end

  sig { params(task_run: AiAgentTaskRun).returns(T.nilable(Superagent)) }
  def resolve_superagent(task_run)
    # Extract superagent from task path if possible, or use first available
    T.must(task_run.ai_agent).superagent_members.first&.superagent
  end

  sig { params(tenant: Tenant, task_run: AiAgentTaskRun).void }
  def set_context(tenant, task_run)
    # Save existing context so we can restore it after the job completes
    # This is important for test isolation when jobs run inline
    @saved_tenant_subdomain = Tenant.current_subdomain
    @saved_tenant_id = Tenant.current_id
    @saved_main_superagent_id = Tenant.current_main_superagent_id
    @saved_superagent_id = Superagent.current_id
    @saved_superagent_handle = Superagent.current_handle
    @saved_task_run_id = AiAgentTaskRun.current_id

    Tenant.current_subdomain = tenant.subdomain
    Tenant.current_id = tenant.id
    Tenant.current_main_superagent_id = tenant.main_superagent_id

    # Set task run context for resource tracking
    AiAgentTaskRun.current_id = task_run.id

    # Clear any stale superagent context before conditionally setting new one
    Superagent.clear_thread_scope

    superagent = resolve_superagent(task_run)
    return unless superagent

    Thread.current[:superagent_id] = superagent.id
    Thread.current[:superagent_handle] = superagent.handle
  end

  sig { void }
  def restore_context
    # Restore previous context instead of just clearing
    # This ensures test isolation when jobs run inline via perform_now
    Thread.current[:tenant_subdomain] = @saved_tenant_subdomain
    Thread.current[:tenant_id] = @saved_tenant_id
    Thread.current[:main_superagent_id] = @saved_main_superagent_id
    Thread.current[:superagent_id] = @saved_superagent_id
    Thread.current[:superagent_handle] = @saved_superagent_handle
    Thread.current[:ai_agent_task_run_id] = @saved_task_run_id
  end

  sig { params(ai_agent_id: String, tenant_id: String).void }
  def schedule_next_task(ai_agent_id, tenant_id)
    AgentQueueProcessorJob.perform_later(ai_agent_id: ai_agent_id, tenant_id: tenant_id)
  end
end
