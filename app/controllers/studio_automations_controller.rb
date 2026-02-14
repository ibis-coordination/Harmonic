# typed: false

# Manages studio-level automation rules (rules scoped to superagent, not AI agent).
# Studio automations use 'actions' array format, not 'task' template.
class StudioAutomationsController < ApplicationController
  # Make path helpers available to views
  helper_method :automations_index_path, :automation_path

  before_action :require_user
  before_action :require_studio_admin
  before_action :set_sidebar_mode, only: [:index, :new, :show, :edit, :runs]
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

  # GET /studios/:superagent_handle/settings/automations
  def index
    @page_title = "Automations - #{@current_superagent.name}"
    @automation_rules = AutomationRule.tenant_scoped_only
      .where(superagent_id: @current_superagent.id)
      .where(ai_agent_id: nil)
      .order(created_at: :desc)
  end

  # GET /studios/:superagent_handle/settings/automations/:automation_id
  def show
    @page_title = "#{@automation_rule.name} - #{@current_superagent.name}"
    @recent_runs = @automation_rule.automation_rule_runs.recent.limit(10)
  end

  # GET /studios/:superagent_handle/settings/automations/new
  def new
    @page_title = "New Automation - #{@current_superagent.name}"
    @yaml_source = params[:yaml_source] || default_template
  end

  # GET /studios/:superagent_handle/settings/automations/:automation_id/edit
  def edit
    @page_title = "Edit #{@automation_rule.name} - #{@current_superagent.name}"
  end

  # GET /studios/:superagent_handle/settings/automations/:automation_id/runs
  def runs
    @page_title = "Run History - #{@automation_rule.name}"
    @runs = @automation_rule.automation_rule_runs.recent.limit(50)
  end

  # === Actions Index ===

  def actions_index_new
    render_actions_index(actions: [
                           { name: "create_automation_rule", params_string: "(yaml_source)", description: "Create a new automation rule" },
                         ])
  end

  def actions_index_show
    render_actions_index(actions: [
                           { name: "update_automation_rule", params_string: "(yaml_source)", description: "Update the automation rule" },
                           { name: "delete_automation_rule", params_string: "()", description: "Delete the automation rule" },
                           { name: "toggle_automation_rule", params_string: "()", description: "Enable or disable the automation rule" },
                         ])
  end

  def actions_index_edit
    render_actions_index(actions: [
                           { name: "update_automation_rule", params_string: "(yaml_source)", description: "Update the automation rule" },
                         ])
  end

  # === Create ===

  def describe_create
    render_action_description({
                                action_name: "create_automation_rule",
                                resource: nil,
                                description: "Create a new studio automation rule from YAML configuration",
                                params: [
                                  { name: "yaml_source", type: "string", description: "YAML configuration for the automation rule" },
                                ],
                              })
  end

  def execute_create
    yaml_source = params[:yaml_source]

    if yaml_source.blank?
      return render_action_error({
                                   action_name: "create_automation_rule",
                                   resource: nil,
                                   error: "YAML configuration is required",
                                 })
    end

    result = AutomationYamlParser.parse(yaml_source, ai_agent_id: nil)

    unless result.success
      return render_action_error({
                                   action_name: "create_automation_rule",
                                   resource: nil,
                                   error: result.errors.join(", "),
                                 })
    end

    rule = AutomationRule.new(
      result.attributes.merge(
        tenant: @current_tenant,
        superagent: @current_superagent,
        ai_agent_id: nil,
        created_by: @current_user,
        yaml_source: yaml_source
      )
    )

    if rule.save
      render_action_success({
                              action_name: "create_automation_rule",
                              resource: rule,
                              result: "Automation rule '#{rule.name}' created successfully.",
                              redirect_to: automation_path(rule),
                            })
    else
      render_action_error({
                            action_name: "create_automation_rule",
                            resource: nil,
                            error: rule.errors.full_messages.join(", "),
                          })
    end
  end

  # === Update ===

  def describe_update
    render_action_description({
                                action_name: "update_automation_rule",
                                resource: @automation_rule,
                                description: "Update the automation rule from YAML configuration",
                                params: [
                                  { name: "yaml_source", type: "string", description: "Updated YAML configuration" },
                                ],
                              })
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

    result = AutomationYamlParser.parse(yaml_source, ai_agent_id: nil)

    unless result.success
      return render_action_error({
                                   action_name: "update_automation_rule",
                                   resource: @automation_rule,
                                   error: result.errors.join(", "),
                                 })
    end

    if @automation_rule.update(result.attributes.merge(yaml_source: yaml_source, updated_by: @current_user))
      render_action_success({
                              action_name: "update_automation_rule",
                              resource: @automation_rule,
                              result: "Automation rule '#{@automation_rule.name}' updated successfully.",
                            })
    else
      render_action_error({
                            action_name: "update_automation_rule",
                            resource: @automation_rule,
                            error: @automation_rule.errors.full_messages.join(", "),
                          })
    end
  end

  # === Delete ===

  def describe_delete
    render_action_description({
                                action_name: "delete_automation_rule",
                                resource: @automation_rule,
                                description: "Permanently delete the automation rule",
                                params: [],
                              })
  end

  def execute_delete
    @automation_rule.destroy!
    render_action_success({
                            action_name: "delete_automation_rule",
                            resource: nil,
                            result: "Automation rule deleted successfully.",
                            redirect_to: automations_index_path,
                          })
  end

  # === Toggle ===

  def describe_toggle
    action = @automation_rule.enabled? ? "disable" : "enable"
    render_action_description({
                                action_name: "toggle_automation_rule",
                                resource: @automation_rule,
                                description: "#{action.capitalize} the automation rule",
                                params: [],
                              })
  end

  def execute_toggle
    @automation_rule.update!(enabled: !@automation_rule.enabled?, updated_by: @current_user)
    state = @automation_rule.enabled? ? "enabled" : "disabled"
    render_action_success({
                            action_name: "toggle_automation_rule",
                            resource: @automation_rule,
                            result: "Automation rule #{state}.",
                          })
  end

  private

  def require_user
    return if current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.md { render plain: "# Error\n\nYou must be logged in to manage automations.", status: :unauthorized }
    end
  end

  def require_studio_admin
    return if @current_user.superagent_member&.is_admin?

    respond_to do |format|
      format.html { redirect_to @current_superagent.path, alert: "You must be a studio admin to manage automations." }
      format.json { render json: { error: "Forbidden" }, status: :forbidden }
      format.md { render plain: "# Error\n\nYou must be a studio admin to manage automations.", status: :forbidden }
    end
  end

  def set_sidebar_mode
    @sidebar_mode = "settings"
    @team = @current_superagent.team
  end

  def set_automation_rule
    @automation_rule = AutomationRule.tenant_scoped_only
      .where(superagent_id: @current_superagent.id)
      .where(ai_agent_id: nil)
      .find_by!(truncated_id: params[:automation_id])
  rescue ActiveRecord::RecordNotFound
    respond_to do |format|
      format.html { redirect_to automations_index_path, alert: "Automation rule not found." }
      format.json { render json: { error: "Automation rule not found" }, status: :not_found }
      format.md { render plain: "# Error\n\nAutomation rule not found.", status: :not_found }
    end
  end

  def automations_index_path
    "/studios/#{@current_superagent.handle}/settings/automations"
  end

  def automation_path(rule)
    "/studios/#{@current_superagent.handle}/settings/automations/#{rule.truncated_id}"
  end

  def default_template
    <<~YAML
      name: "New Studio Automation"
      description: "Describe what this automation does"

      trigger:
        type: event
        event_type: note.created

      actions:
        - type: webhook
          url: "https://example.com/webhook"
          method: POST
          payload:
            text: "New note created: {{subject.title}}"
    YAML
  end
end
