# typed: true

class AutomationExecutor
  extend T::Sig

  # Execute an automation rule run
  sig { params(run: AutomationRuleRun).void }
  def self.execute(run)
    new(run).execute
  end

  sig { params(run: AutomationRuleRun).void }
  def initialize(run)
    @run = run
    @rule = run.automation_rule
    @event = run.triggered_by_event
  end

  sig { void }
  def execute
    @run.mark_running!

    if @rule.agent_rule?
      execute_agent_rule
    else
      execute_general_rule
    end

    @rule.increment_execution_count!
  rescue StandardError => e
    @run.mark_failed!(e.message)
    Rails.logger.error("AutomationExecutor failed for run #{@run.id}: #{e.message}")
    raise
  end

  private

  sig { void }
  def execute_agent_rule
    ai_agent = @rule.ai_agent
    unless ai_agent
      @run.mark_failed!("AI agent not found")
      return
    end

    # Build the task prompt from the template
    task_prompt = render_task_prompt
    if task_prompt.blank?
      @run.mark_failed!("Task prompt is empty")
      return
    end

    # Determine who initiated this task
    # For event-triggered rules, use the event actor
    # For schedule/webhook triggers, use the rule creator
    initiated_by = @event&.actor || @rule.created_by

    # Create the task run
    task_run = AiAgentTaskRun.create_queued(
      ai_agent: ai_agent,
      tenant: @rule.tenant,
      initiated_by: initiated_by,
      task: task_prompt,
      max_steps: @rule.max_steps
    )

    # Link the automation run to the task run
    @run.link_to_task_run!(task_run)

    # Kick off the queue processor
    AgentQueueProcessorJob.perform_later(ai_agent_id: ai_agent.id, tenant_id: @rule.tenant_id)

    @run.mark_completed!(executed_actions: [{ type: "trigger_agent", task_run_id: task_run.id }])
  end

  sig { void }
  def execute_general_rule
    actions = @rule.actions
    unless actions.is_a?(Array)
      @run.mark_failed!("Actions must be an array")
      return
    end

    executed_actions = []

    actions.each_with_index do |action, index|
      action_type = action["type"]

      case action_type
      when "internal_action"
        result = execute_internal_action(action)
        executed_actions << { index: index, type: action_type, result: result }
      when "webhook"
        # Webhook sending will be implemented in Phase 4
        executed_actions << { index: index, type: action_type, result: "skipped - not implemented" }
      when "trigger_agent"
        result = execute_trigger_agent_action(action)
        executed_actions << { index: index, type: action_type, result: result }
      else
        executed_actions << { index: index, type: action_type, result: "unknown action type" }
      end
    end

    @run.mark_completed!(executed_actions: executed_actions)
  end

  sig { returns(String) }
  def render_task_prompt
    task_template = @rule.task_template
    return "" if task_template.blank?

    if @event
      context = AutomationTemplateRenderer.context_from_event(@event)
      AutomationTemplateRenderer.render(task_template, context)
    else
      # For scheduled triggers without an event
      task_template
    end
  end

  sig { params(action: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def execute_internal_action(action)
    action_name = action["action"]
    params = action["params"] || {}

    # Render any template variables in params
    rendered_params = render_params(params)

    # Internal actions will be implemented in Phase 3
    # For now, just record what would be executed
    {
      action: action_name,
      params: rendered_params,
      status: "skipped - not implemented",
    }
  end

  sig { params(action: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def execute_trigger_agent_action(action)
    agent_id = action["agent_id"]
    task_template = action["task"]

    agent = User.find_by(id: agent_id)
    return { status: "failed", error: "Agent not found or not an AI agent" } unless agent&.ai_agent?

    task_prompt = if @event
                    context = AutomationTemplateRenderer.context_from_event(@event)
                    AutomationTemplateRenderer.render(task_template, context)
                  else
                    task_template
                  end

    initiated_by = @event&.actor || @rule.created_by

    task_run = AiAgentTaskRun.create_queued(
      ai_agent: agent,
      tenant: @rule.tenant,
      initiated_by: initiated_by,
      task: task_prompt,
      max_steps: action["max_steps"]&.to_i
    )

    AgentQueueProcessorJob.perform_later(ai_agent_id: agent.id, tenant_id: @rule.tenant_id)

    { status: "success", task_run_id: task_run.id }
  end

  sig { params(params: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def render_params(params)
    return {} unless @event

    context = AutomationTemplateRenderer.context_from_event(@event)

    params.transform_values do |value|
      if value.is_a?(String)
        AutomationTemplateRenderer.render(value, context)
      else
        value
      end
    end
  end
end
