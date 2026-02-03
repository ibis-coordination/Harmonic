# typed: true

class AgentTaskJob < ApplicationJob
  extend T::Sig

  queue_as :default

  # Allow injecting a mock navigator class for testing
  class_attribute :navigator_class, default: AgentNavigator

  sig do
    params(
      subagent_id: String,
      tenant_id: String,
      superagent_id: String,
      initiated_by_id: String,
      trigger_context: T::Hash[Symbol, T.untyped]
    ).void
  end
  def perform(subagent_id:, tenant_id:, superagent_id:, initiated_by_id:, trigger_context:)
    # Load records
    tenant = Tenant.find_by(id: tenant_id)
    superagent = Superagent.find_by(id: superagent_id)
    subagent = User.find_by(id: subagent_id)
    initiated_by = User.find_by(id: initiated_by_id)

    # Guard clauses
    return unless tenant && superagent && subagent && initiated_by
    return unless subagent.subagent?
    return unless tenant.subagents_enabled?

    # Set thread-local context (same pattern as ReminderDeliveryJob)
    set_tenant_context(tenant)
    set_superagent_context(superagent)

    begin
      run_agent_task(tenant, superagent, subagent, initiated_by, trigger_context)
    ensure
      clear_context
    end
  end

  private

  sig do
    params(
      tenant: Tenant,
      superagent: Superagent,
      subagent: User,
      initiated_by: User,
      trigger_context: T::Hash[Symbol, T.untyped]
    ).void
  end
  def run_agent_task(tenant, superagent, subagent, initiated_by, trigger_context)
    task_prompt = build_task_prompt(trigger_context)

    task_run = SubagentTaskRun.create!(
      tenant: tenant,
      subagent: subagent,
      initiated_by: initiated_by,
      task: task_prompt,
      max_steps: 15,
      status: "running",
      started_at: Time.current
    )

    navigator = self.class.navigator_class.new(
      user: subagent,
      tenant: tenant,
      superagent: superagent
    )

    result = navigator.run(task: task_prompt, max_steps: task_run.max_steps)

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

  sig { params(trigger_context: T::Hash[Symbol, T.untyped]).returns(String) }
  def build_task_prompt(trigger_context)
    actor_name = trigger_context[:actor_name] || "Someone"
    item_path = trigger_context[:item_path]

    "You were mentioned by #{actor_name}. Navigate to #{item_path} to see the context and respond appropriately by adding a comment."
  end

  # Context methods (same pattern as ReminderDeliveryJob)
  sig { params(tenant: Tenant).void }
  def set_tenant_context(tenant)
    Tenant.current_subdomain = tenant.subdomain
    Tenant.current_id = tenant.id
    Tenant.current_main_superagent_id = tenant.main_superagent_id
  end

  sig { params(superagent: Superagent).void }
  def set_superagent_context(superagent)
    Thread.current[:superagent_id] = superagent.id
    Thread.current[:superagent_handle] = superagent.handle
  end

  sig { void }
  def clear_context
    Tenant.clear_thread_scope
    Superagent.clear_thread_scope
  end
end
