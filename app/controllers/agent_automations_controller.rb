# typed: false

class AgentAutomationsController < ApplicationController
  before_action :require_login
  before_action :set_ai_agent
  before_action :authorize_parent_user
  before_action :set_sidebar_mode, only: [:index, :new, :show, :edit, :templates, :runs]
  before_action :set_automation_rule, only: [
    :show, :edit, :runs,
    :actions_index_show, :actions_index_edit,
    :describe_update, :execute_update,
    :describe_delete, :execute_delete,
    :describe_toggle, :execute_toggle,
  ]

  def current_resource_model
    AutomationRule
  end

  # GET /ai-agents/:handle/automations
  def index
    @page_title = "Automations - #{@ai_agent.display_name}"
    @automation_rules = AutomationRule.tenant_scoped_only
      .where(ai_agent_id: @ai_agent.id)
      .order(created_at: :desc)
  end

  # GET /ai-agents/:handle/automations/new
  def new
    @page_title = "New Automation - #{@ai_agent.display_name}"
    @template_yaml = params[:template].present? ? load_template(params[:template]) : default_template
  end

  # GET /ai-agents/:handle/automations/templates
  def templates
    @page_title = "Automation Templates - #{@ai_agent.display_name}"
    @templates = AutomationTemplateGallery.all
  end

  # GET /ai-agents/:handle/automations/:automation_id
  def show
    @page_title = "#{@automation_rule.name} - #{@ai_agent.display_name}"
    @recent_runs = AutomationRuleRun.tenant_scoped_only
      .where(automation_rule_id: @automation_rule.id)
      .order(created_at: :desc)
      .limit(20)
  end

  # GET /ai-agents/:handle/automations/:automation_id/edit
  def edit
    @page_title = "Edit: #{@automation_rule.name}"
  end

  # GET /ai-agents/:handle/automations/:automation_id/runs
  def runs
    @page_title = "Run History - #{@automation_rule.name}"
    @runs = AutomationRuleRun.tenant_scoped_only
      .where(automation_rule_id: @automation_rule.id)
      .order(created_at: :desc)
      .limit(50)
  end

  # Actions index routes
  def actions_index_new
    render_actions_index(ActionsHelper.actions_for_route("/ai-agents/:handle/automations/new"))
  end

  def actions_index_show
    render_actions_index(ActionsHelper.actions_for_route("/ai-agents/:handle/automations/:automation_id"))
  end

  def actions_index_edit
    render_actions_index(ActionsHelper.actions_for_route("/ai-agents/:handle/automations/:automation_id/edit"))
  end

  # Create automation
  def describe_create
    render_action_description(ActionsHelper.action_description("create_automation_rule", resource: @ai_agent))
  end

  def execute_create
    yaml_source = params[:yaml_source]

    if yaml_source.blank?
      return render_action_error({
        action_name: "create_automation_rule",
        resource: @ai_agent,
        error: "YAML configuration is required",
      })
    end

    result = AutomationYamlParser.parse(yaml_source, ai_agent_id: @ai_agent.id)

    unless result.success?
      return render_action_error({
        action_name: "create_automation_rule",
        resource: @ai_agent,
        error: result.errors.join(", "),
      })
    end

    attributes = result.attributes
    return render_action_error({
      action_name: "create_automation_rule",
      resource: @ai_agent,
      error: "Failed to parse YAML",
    }) if attributes.nil?

    automation_rule = AutomationRule.new(
      tenant: @current_tenant,
      ai_agent: @ai_agent,
      created_by: @current_user,
      yaml_source: yaml_source,
      **attributes
    )

    if automation_rule.save
      render_action_success({
        action_name: "create_automation_rule",
        resource: automation_rule,
        result: "Automation rule '#{automation_rule.name}' created successfully",
        redirect_to: automation_path(automation_rule),
      })
    else
      render_action_error({
        action_name: "create_automation_rule",
        resource: @ai_agent,
        error: automation_rule.errors.full_messages.join(", "),
      })
    end
  end

  # Update automation
  def describe_update
    render_action_description(ActionsHelper.action_description("update_automation_rule", resource: @automation_rule))
  end

  def execute_update
    yaml_source = params[:yaml_source]

    if yaml_source.blank?
      return render_action_error({
        action_name: "update_automation_rule",
        resource: @automation_rule,
        error: "YAML configuration is required",
      })
    end

    result = AutomationYamlParser.parse(yaml_source, ai_agent_id: @ai_agent.id)

    unless result.success?
      return render_action_error({
        action_name: "update_automation_rule",
        resource: @automation_rule,
        error: result.errors.join(", "),
      })
    end

    attributes = result.attributes
    return render_action_error({
      action_name: "update_automation_rule",
      resource: @automation_rule,
      error: "Failed to parse YAML",
    }) if attributes.nil?

    if @automation_rule.update(yaml_source: yaml_source, **attributes)
      render_action_success({
        action_name: "update_automation_rule",
        resource: @automation_rule,
        result: "Automation rule '#{@automation_rule.name}' updated successfully",
        redirect_to: automation_path(@automation_rule),
      })
    else
      render_action_error({
        action_name: "update_automation_rule",
        resource: @automation_rule,
        error: @automation_rule.errors.full_messages.join(", "),
      })
    end
  end

  # Delete automation
  def describe_delete
    render_action_description(ActionsHelper.action_description("delete_automation_rule", resource: @automation_rule))
  end

  def execute_delete
    name = @automation_rule.name
    @automation_rule.destroy!

    render_action_success({
      action_name: "delete_automation_rule",
      resource: nil,
      result: "Automation rule '#{name}' deleted",
      redirect_to: automations_index_path,
    })
  end

  # Toggle enabled/disabled
  def describe_toggle
    render_action_description(ActionsHelper.action_description("toggle_automation_rule", resource: @automation_rule))
  end

  def execute_toggle
    new_state = !@automation_rule.enabled?
    @automation_rule.update!(enabled: new_state)

    render_action_success({
      action_name: "toggle_automation_rule",
      resource: @automation_rule,
      result: "Automation rule '#{@automation_rule.name}' #{new_state ? 'enabled' : 'disabled'}",
      redirect_to: automation_path(@automation_rule),
    })
  end

  private

  def set_sidebar_mode
    @sidebar_mode = "minimal"
  end

  def require_login
    return if @current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.md { render plain: "# Error\n\nYou must be logged in to manage automations.", status: :unauthorized }
    end
  end

  def set_ai_agent
    agent_tu = @current_tenant.tenant_users.find_by(handle: params[:handle])
    raise ActiveRecord::RecordNotFound, "AI Agent not found" if agent_tu.nil?

    @ai_agent = agent_tu.user
    raise ActiveRecord::RecordNotFound, "AI Agent not found" unless @ai_agent&.ai_agent?

    @agent_handle = params[:handle]
  end

  def authorize_parent_user
    # Only parent user can manage their AI agent's automations
    return if @ai_agent.parent_id == @current_user.id

    respond_to do |format|
      format.html { redirect_to "/", alert: "You don't have permission to manage automations for this AI agent" }
      format.json { render json: { error: "Forbidden" }, status: :forbidden }
      format.md { render plain: "# Error\n\nYou don't have permission to manage automations for this AI agent.", status: :forbidden }
    end
  end

  def set_automation_rule
    @automation_rule = AutomationRule.tenant_scoped_only
      .where(ai_agent_id: @ai_agent.id)
      .find_by!(truncated_id: params[:automation_id])
  end

  def automations_index_path
    "/ai-agents/#{@agent_handle}/automations"
  end

  def automation_path(rule)
    "/ai-agents/#{@agent_handle}/automations/#{rule.truncated_id}"
  end

  def default_template
    <<~YAML
      name: "My Automation"
      description: "Describe what this automation does"

      trigger:
        type: event
        event_type: note.created
        mention_filter: self

      task: |
        You were mentioned by {{event.actor.name}} in {{subject.path}}.
        Navigate there, read the context, and respond appropriately.

      max_steps: 20
    YAML
  end

  def load_template(template_key)
    template = AutomationTemplateGallery.find(template_key)
    template&.yaml_content || default_template
  end
end
