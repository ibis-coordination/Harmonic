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
      max_steps: @rule.max_steps,
      automation_rule: @rule
    )

    # Link the automation run to the task run
    @run.link_to_task_run!(task_run)

    # Kick off the queue processor
    AgentQueueProcessorJob.perform_later(ai_agent_id: ai_agent.id, tenant_id: @rule.tenant_id)

    # Record the action but don't mark as completed - task run will report back when done
    @run.record_actions!(executed_actions: [{ type: "trigger_agent", task_run_id: task_run.id }])
  end

  sig { void }
  def execute_general_rule
    actions = @rule.actions
    unless actions.is_a?(Array)
      @run.mark_failed!("Actions must be an array")
      return
    end

    executed_actions = []
    has_async_actions = false

    actions.each_with_index do |action, index|
      action_type = action["type"]

      case action_type
      when "internal_action"
        result = execute_internal_action(action)
        executed_actions << { index: index, type: action_type, result: result }
      when "webhook"
        result = execute_webhook_action(action)
        executed_actions << { index: index, type: action_type, result: result }
        # Only count as async if webhook delivery was actually created
        has_async_actions = true if result[:success] && result[:delivery_id].present?
      when "trigger_agent"
        result = execute_trigger_agent_action(action)
        executed_actions << { index: index, type: action_type, result: result }
        # Only count as async if task run was actually created
        has_async_actions = true if result[:status] == "success" && result[:task_run_id].present?
      else
        executed_actions << { index: index, type: action_type, result: "unknown action type" }
      end
    end

    if has_async_actions
      # Async actions (webhooks, trigger_agent) will report back when done
      @run.record_actions!(executed_actions: executed_actions)
    else
      # Only sync actions (internal_action), safe to mark completed
      @run.mark_completed!(executed_actions: executed_actions)
    end
  end

  sig { returns(String) }
  def render_task_prompt
    task_template = @rule.task_template
    return "" if task_template.blank?

    context = build_template_context
    if context.present?
      AutomationTemplateRenderer.render(task_template, context)
    else
      task_template
    end
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def build_template_context
    if @event
      AutomationTemplateRenderer.context_from_event(@event)
    elsif @run.trigger_data.present?
      AutomationTemplateRenderer.context_from_trigger_data(@run.trigger_data)
    else
      {}
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

  sig { params(action: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def execute_webhook_action(action)
    url = action["url"]
    return { success: false, error: "URL is required for webhook action" } if url.blank?

    # Basic URL format validation (SSRF protection is handled by ssrf_filter at delivery time)
    begin
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        return { success: false, error: "URL must be HTTP or HTTPS" }
      end
      return { success: false, error: "URL must have a hostname" } if uri.host.blank?
    rescue URI::InvalidURIError
      return { success: false, error: "Invalid URL format" }
    end

    # Build the request body with template rendering
    # Accept both "body" and "payload" keys for user convenience
    body = build_webhook_body(action["payload"] || action["body"] || {})

    # Create a WebhookDelivery record for tracking and retries
    delivery = WebhookDelivery.create!(
      tenant: @rule.tenant,
      automation_rule_run: @run,
      event: @event,
      url: url,
      secret: @rule.webhook_secret,
      request_body: body.to_json,
      status: "pending",
    )

    # Queue async delivery with retry support
    WebhookDeliveryJob.perform_later(delivery.id)

    { success: true, delivery_id: delivery.id, status: "queued" }
  rescue StandardError => e
    { success: false, error: e.message }
  end

  sig { params(body: T.untyped).returns(T.untyped) }
  def build_webhook_body(body)
    context = build_template_context
    return body if context.empty?

    render_body_recursive(body, context)
  end

  sig { params(value: T.untyped, context: T::Hash[String, T.untyped]).returns(T.untyped) }
  def render_body_recursive(value, context)
    case value
    when Hash
      value.transform_values { |v| render_body_recursive(v, context) }
    when Array
      value.map { |v| render_body_recursive(v, context) }
    when String
      AutomationTemplateRenderer.render(value, context)
    else
      value
    end
  end

  sig { params(action: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def execute_trigger_agent_action(action)
    agent_id = action["agent_id"]
    task_template = action["task"]

    agent = User.find_by(id: agent_id)
    return { status: "failed", error: "Agent not found or not an AI agent" } unless agent&.ai_agent?

    # Authorization check: can the rule creator trigger this agent?
    auth_result = authorize_agent_trigger(agent)
    return auth_result unless auth_result["authorized"]

    context = build_template_context
    task_prompt = if context.present?
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
      max_steps: action["max_steps"]&.to_i,
      automation_rule: @rule
    )

    AgentQueueProcessorJob.perform_later(ai_agent_id: agent.id, tenant_id: @rule.tenant_id)

    { status: "success", task_run_id: task_run.id }
  end

  sig { params(params: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def render_params(params)
    context = build_template_context
    return params if context.empty?

    params.transform_values do |value|
      if value.is_a?(String)
        AutomationTemplateRenderer.render(value, context)
      else
        value
      end
    end
  end

  # Check if the rule creator is authorized to trigger a specific agent
  # Returns { "authorized" => true } or { "status" => "failed", "error" => "..." }
  sig { params(agent: User).returns(T::Hash[String, T.untyped]) }
  def authorize_agent_trigger(agent)
    rule_creator = @rule.created_by

    # Rule creator owns the agent (is the parent)
    if agent.parent_id == rule_creator.id
      return { "authorized" => true }
    end

    # For studio rules: check if the agent is a member of the same studio
    if @rule.studio_rule? && @rule.superagent_id.present?
      agent_is_studio_member = SuperagentMember
        .where(superagent_id: @rule.superagent_id, user_id: agent.id)
        .exists?

      if agent_is_studio_member
        return { "authorized" => true }
      end
    end

    # Not authorized
    {
      "status" => "failed",
      "error" => "Not authorized to trigger agent '#{agent.display_name}'. You can only trigger agents you own or agents that are members of this studio.",
    }
  end
end
