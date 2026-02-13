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

    superagent = resolve_superagent(task_run)
    set_superagent_context!(superagent) if superagent

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

  sig { params(ai_agent_id: String, tenant_id: String).void }
  def schedule_next_task(ai_agent_id, tenant_id)
    AgentQueueProcessorJob.perform_later(ai_agent_id: ai_agent_id, tenant_id: tenant_id)
  end
end
