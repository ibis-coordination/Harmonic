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

    if @rule.internal_agent_rule?
      execute_internal_agent_rule
    elsif @rule.notification_webhook_rule?
      execute_notification_webhook_rule
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
  def execute_internal_agent_rule
    ai_agent = @rule.ai_agent
    unless ai_agent
      @run.mark_failed!("AI agent not found")
      return
    end

    # Agent-owned rules trigger the AI agent via the Task Runner — gated on
    # the internal AI agents flag and the agent being internal-mode. System
    # agents (Trio) run on the deployment's account and are inherently
    # internal-mode; exempt them from both checks, same as billing.
    unless ai_agent.system?
      unless @rule.tenant.internal_ai_agents_enabled?
        @run.mark_failed!("Internal AI Agents are not enabled for this tenant.")
        return
      end

      unless ai_agent.internal_ai_agent?
        @run.mark_failed!("Agent-owned automations require an internal-mode agent. External agents cannot be triggered by the Task Runner.")
        return
      end
    end

    # Agent must be active (not archived, suspended, or pending billing)
    if ai_agent.pending_billing_setup?
      @run.mark_failed!("Agent is pending billing setup. Set up billing at /billing to activate this agent.")
      return
    end

    if ai_agent.suspended?
      @run.mark_failed!("Agent is suspended. Unsuspend the agent before running automations.")
      return
    end

    agent_tenant_user = ai_agent.tenant_users.find_by(tenant_id: @rule.tenant_id)
    if agent_tenant_user&.archived?
      @run.mark_failed!("Agent is deactivated. Reactivate the agent before running automations.")
      return
    end

    # Billing gate: if stripe_billing is enabled, the agent's identity must be
    # paid for (an active billing_customer). The one exception is a free-account
    # principal (nothing billable — e.g. an app admin), which owes no per-identity
    # fee; billable_quantity of zero is exactly that case. System agents (e.g.,
    # Trio) are exempt: they have no principal and run on the deployment's
    # account. Pool-funded agents skip individual billing — enrolled members
    # fund them per call. The prepaid-credit requirement is enforced
    # authoritatively when the task dispatches (AgentRunnerDispatchService),
    # which this mirrors.
    if @rule.tenant.feature_enabled?("stripe_billing") && !ai_agent.system? && ai_agent.funding_pool_id.nil? &&
       !(ai_agent.resolved_billing_customer&.active? || ai_agent.parent&.billable_quantity&.zero?)
      @run.mark_failed!("Billing is not set up for this agent's billing customer. Set up billing at /billing.")
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

    # Dispatch to the agent-runner service via Redis stream.
    # AgentRunnerDispatchService re-runs billing/status checks and will mark
    # the task failed (and notify this automation run) if they don't pass.
    AgentRunnerDispatchService.dispatch(task_run)

    # Record the action but don't mark as completed - task run will report back when done
    @run.record_actions!(executed_actions: [{ type: "trigger_agent", task_run_id: task_run.id }])
  end

  sig { void }
  def execute_notification_webhook_rule
    recipient = @rule.ai_agent || @rule.user
    unless recipient
      @run.mark_failed!("Recipient not found")
      return
    end

    if recipient.suspended?
      @run.mark_failed!("Recipient is suspended.")
      return
    end

    recipient_tu = recipient.tenant_users.find_by(tenant_id: @rule.tenant_id)
    if recipient_tu.nil? || recipient_tu.archived?
      @run.mark_failed!("Recipient no longer active in this tenant.")
      return
    end

    # No billing gate: notification webhooks don't use the Task Runner or LLM
    # credits, so the $3/month subscription model doesn't apply.

    webhook_url = @rule.actions.is_a?(Hash) ? @rule.actions["webhook_url"] : nil
    payload_template = @rule.actions.is_a?(Hash) ? @rule.actions["payload_template"] : nil

    if webhook_url.blank?
      @run.mark_failed!("Webhook URL missing.")
      return
    end

    body = build_webhook_body(payload_template || {})

    delivery = create_webhook_delivery(url: webhook_url, secret: @rule.webhook_secret, request_body: body.to_json)
    WebhookDeliveryJob.perform_later(delivery.id)

    @run.record_actions!(executed_actions: [{ "type" => "webhook", "delivery_id" => delivery.id }])
  end

  sig { void }
  def execute_general_rule
    actions = @rule.actions
    unless actions.is_a?(Array)
      @run.mark_failed!("Actions must be an array")
      return
    end

    executed_actions = []
    has_async_actions = T.let(false, T::Boolean)

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
        has_async_actions = true if result["status"] == "success" && result["delivery_id"].present?
      when "trigger_agent"
        result = execute_trigger_agent_action(action)
        executed_actions << { index: index, type: action_type, result: result }
        # Only count as async if task run was actually created
        has_async_actions = true if result["status"] == "success" && result["task_run_id"].present?
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

    return { "action" => action_name, "status" => "failed", "error" => "Action name is required" } if action_name.blank?

    # Render any template variables in params
    rendered_params = render_params(params)

    # Execute using the internal action service
    service = AutomationInternalActionService.new(@run)
    result = service.execute(action_name, rendered_params.stringify_keys)

    if result.success
      {
        "action" => action_name,
        "params" => rendered_params,
        "status" => "success",
        "resource_id" => result.resource_id,
        "resource_path" => result.resource_path,
        "message" => result.message,
      }
    else
      {
        "action" => action_name,
        "params" => rendered_params,
        "status" => "failed",
        "error" => result.error,
      }
    end
  end

  sig { params(action: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def execute_webhook_action(action)
    url = action["url"]
    return { "status" => "failed", "error" => "URL is required for webhook action" } if url.blank?

    # Basic URL format validation (SSRF protection is handled by ssrf_filter at delivery time)
    begin
      uri = URI.parse(url)
      return { "status" => "failed", "error" => "URL must be HTTP or HTTPS" } unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return { "status" => "failed", "error" => "URL must have a hostname" } if uri.host.blank?
    rescue URI::InvalidURIError
      return { "status" => "failed", "error" => "Invalid URL format" }
    end

    # Build the request body with template rendering
    # Accept both "body" and "payload" keys for user convenience
    body = build_webhook_body(action["payload"] || action["body"] || {})

    delivery = create_webhook_delivery(url: url, secret: @rule.webhook_secret, request_body: body.to_json)
    WebhookDeliveryJob.perform_later(delivery.id)

    { "status" => "success", "delivery_id" => delivery.id }
  rescue StandardError => e
    { "status" => "failed", "error" => e.message }
  end

  # Factored shared helper for creating a pending WebhookDelivery record.
  # Both the collective-rule webhook-action path and the external-agent-rule
  # path use this so the WebhookDelivery constructor lives in one place.
  sig { params(url: String, secret: String, request_body: String).returns(WebhookDelivery) }
  def create_webhook_delivery(url:, secret:, request_body:)
    WebhookDelivery.create!(
      tenant: @rule.tenant,
      automation_rule_run: @run,
      event: @event,
      url: url,
      secret: secret,
      request_body: request_body,
      status: "pending"
    )
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
    return { "status" => "failed", "error" => "Agent not found or not an AI agent" } unless agent&.ai_agent?

    # trigger_agent dispatches via the Task Runner — gated on the internal AI
    # agents flag and the target agent being internal-mode. System agents (Trio)
    # are exempt from both checks (same as billing).
    unless agent.system?
      unless @rule.tenant.internal_ai_agents_enabled?
        return { "status" => "failed", "error" => "Internal AI Agents are not enabled for this tenant." }
      end

      unless agent.internal_ai_agent?
        return { "status" => "failed",
                 "error" => "Cannot trigger external agents via the Task Runner. trigger_agent requires an internal-mode agent.", }
      end
    end

    # Billing gate: if stripe_billing is enabled, the agent's identity must be
    # paid for, with the free-account principal exemption (billable_quantity of
    # zero) — same as the gate above and in AgentRunnerDispatchService. System
    # agents (e.g., Trio) are exempt, as are pool-funded agents (enrolled
    # members fund them per call). The prepaid-credit requirement is enforced
    # at dispatch.
    if @rule.tenant.feature_enabled?("stripe_billing") && !agent.system? && agent.funding_pool_id.nil? &&
       !(agent.resolved_billing_customer&.active? || agent.parent&.billable_quantity&.zero?)
      return { "status" => "failed", "error" => "Billing is not set up for this agent's billing customer. Set up billing at /billing." }
    end

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

    AgentRunnerDispatchService.dispatch(task_run)

    { "status" => "success", "task_run_id" => task_run.id }
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
    return { "authorized" => true } if agent.parent_id == rule_creator.id

    # For collective rules: check if the agent is a member of the same collective
    if @rule.collective_rule? && @rule.collective_id.present?
      agent_is_collective_member = CollectiveMember
        .where(collective_id: @rule.collective_id, user_id: agent.id)
        .exists?

      return { "authorized" => true } if agent_is_collective_member
    end

    # Not authorized
    {
      "status" => "failed",
      "error" => "Not authorized to trigger agent '#{agent.display_name}'. You can only trigger agents you own or agents that are members of this collective.",
    }
  end
end
