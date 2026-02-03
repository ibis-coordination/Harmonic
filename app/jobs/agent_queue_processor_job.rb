# typed: true

class AgentQueueProcessorJob < ApplicationJob
  extend T::Sig

  queue_as :default

  # Allow injecting a mock navigator class for testing
  class_attribute :navigator_class, default: AgentNavigator

  sig { params(subagent_id: String, tenant_id: String).void }
  def perform(subagent_id:, tenant_id:)
    tenant = Tenant.find_by(id: tenant_id)
    subagent = User.find_by(id: subagent_id)

    return unless tenant && subagent
    return unless subagent.subagent?
    return unless tenant.subagents_enabled?

    task_run = claim_next_task(subagent, tenant)
    return unless task_run

    set_context(tenant, task_run)

    begin
      run_task(task_run)
    ensure
      restore_context
      # Check for more queued tasks
      schedule_next_task(subagent_id, tenant_id)
    end
  end

  private

  sig { params(subagent: User, tenant: Tenant).returns(T.nilable(SubagentTaskRun)) }
  def claim_next_task(subagent, tenant)
    claimed_task = T.let(nil, T.nilable(SubagentTaskRun))

    subagent.with_lock do
      # Already running? Exit - the running job will trigger us when done
      next if SubagentTaskRun.exists?(subagent: subagent, tenant: tenant, status: "running")

      # Get oldest queued task
      next_task = SubagentTaskRun
        .where(subagent: subagent, tenant: tenant, status: "queued")
        .order(:created_at)
        .first

      next unless next_task

      # Claim it
      next_task.update!(status: "running", started_at: Time.current)
      claimed_task = next_task
    end

    claimed_task
  end

  sig { params(task_run: SubagentTaskRun).void }
  def run_task(task_run)
    navigator = self.class.navigator_class.new(
      user: task_run.subagent,
      tenant: task_run.tenant,
      superagent: resolve_superagent(task_run)
    )

    result = navigator.run(task: task_run.task, max_steps: task_run.max_steps)

    task_run.update!(
      status: result.success ? "completed" : "failed",
      success: result.success,
      final_message: result.final_message,
      error: result.error,
      steps_count: result.steps.count,
      steps_data: result.steps.map { |s| { type: s.type, detail: s.detail, timestamp: s.timestamp.iso8601 } },
      completed_at: Time.current
    )
  end

  sig { params(task_run: SubagentTaskRun).returns(T.nilable(Superagent)) }
  def resolve_superagent(task_run)
    # Extract superagent from task path if possible, or use first available
    T.must(task_run.subagent).superagent_members.first&.superagent
  end

  sig { params(tenant: Tenant, task_run: SubagentTaskRun).void }
  def set_context(tenant, task_run)
    # Save existing context so we can restore it after the job completes
    # This is important for test isolation when jobs run inline
    @saved_tenant_subdomain = Tenant.current_subdomain
    @saved_tenant_id = Tenant.current_id
    @saved_main_superagent_id = Tenant.current_main_superagent_id
    @saved_superagent_id = Superagent.current_id
    @saved_superagent_handle = Superagent.current_handle
    @saved_task_run_id = SubagentTaskRun.current_id

    Tenant.current_subdomain = tenant.subdomain
    Tenant.current_id = tenant.id
    Tenant.current_main_superagent_id = tenant.main_superagent_id

    # Set task run context for resource tracking
    SubagentTaskRun.current_id = task_run.id

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
    Thread.current[:subagent_task_run_id] = @saved_task_run_id
  end

  sig { params(subagent_id: String, tenant_id: String).void }
  def schedule_next_task(subagent_id, tenant_id)
    AgentQueueProcessorJob.perform_later(subagent_id: subagent_id, tenant_id: tenant_id)
  end
end
