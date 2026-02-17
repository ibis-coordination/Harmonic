# typed: false

# Manages studio-level automation rules (rules scoped to collective, not AI agent).
# Studio automations use 'actions' array format, not 'task' template.
class StudioAutomationsController < ApplicationController
  # Make path helpers available to views
  helper_method :automations_index_path, :automation_path

  before_action :require_user
  before_action :require_studio_admin
  before_action :set_sidebar_mode, only: [:index, :new, :show, :edit, :runs, :run_show]
  before_action :set_automation_rule, only: [
    :show, :edit, :runs, :run_show,
    :actions_index_show, :actions_index_edit,
    :describe_update, :execute_update,
    :describe_delete, :execute_delete,
    :describe_toggle, :execute_toggle,
    :describe_test, :execute_test,
    :describe_run, :execute_run,
  ]

  def current_resource_model
    AutomationRule
  end

  # GET /studios/:collective_handle/settings/automations
  def index
    @page_title = "Automations - #{@current_collective.name}"
    @automation_rules = AutomationRule.tenant_scoped_only
      .where(collective_id: @current_collective.id)
      .where(ai_agent_id: nil)
      .order(created_at: :desc)
  end

  # GET /studios/:collective_handle/settings/automations/:automation_id
  def show
    @page_title = "#{@automation_rule.name} - #{@current_collective.name}"
    @recent_runs = @automation_rule.automation_rule_runs.recent.limit(10)
  end

  # GET /studios/:collective_handle/settings/automations/new
  def new
    @page_title = "New Automation - #{@current_collective.name}"
    @yaml_source = params[:yaml_source] || default_template
  end

  # GET /studios/:collective_handle/settings/automations/:automation_id/edit
  def edit
    @page_title = "Edit #{@automation_rule.name} - #{@current_collective.name}"
  end

  # GET /studios/:collective_handle/settings/automations/:automation_id/runs
  def runs
    @page_title = "Run History - #{@automation_rule.name}"
    @runs = @automation_rule.automation_rule_runs.recent.limit(50)
  end

  # GET /studios/:collective_handle/settings/automations/:automation_id/runs/:run_id
  def run_show
    @run = @automation_rule.automation_rule_runs.find(params[:run_id])
    @page_title = "Run Details - #{@automation_rule.name}"
    @webhook_deliveries = @run.webhook_deliveries.order(created_at: :asc)
  end

  # === Actions Index ===

  def actions_index_new
    render_actions_index(actions: [
                           { name: "create_automation_rule", params_string: "(yaml_source)", description: "Create a new automation rule" },
                         ])
  end

  def actions_index_show
    actions = [
      { name: "update_automation_rule", params_string: "(yaml_source)", description: "Update the automation rule" },
      { name: "delete_automation_rule", params_string: "()", description: "Delete the automation rule" },
      { name: "toggle_automation_rule", params_string: "()", description: "Enable or disable the automation rule" },
      { name: "test_automation_rule", params_string: "()", description: "Test the automation with synthetic data" },
    ]

    # Add run action for manual trigger automations
    if @automation_rule.manual_trigger?
      actions << { name: "run_automation_rule", params_string: "(inputs?)", description: "Run this manual automation" }
    end

    render_actions_index(actions: actions)
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
        collective: @current_collective,
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

  # === Test ===

  def describe_test
    render_action_description({
                                action_name: "test_automation_rule",
                                resource: @automation_rule,
                                description: "Test the automation rule with synthetic data",
                                params: [],
                              })
  end

  def execute_test
    result = AutomationTestService.test!(@automation_rule)

    if result.success?
      run = result.run
      summary = build_test_summary(result)
      render_action_success({
                              action_name: "test_automation_rule",
                              resource: @automation_rule,
                              result: summary,
                              metadata: {
                                run_id: run&.id,
                                actions_executed: result.actions_executed,
                              },
                            })
    else
      render_action_error({
                            action_name: "test_automation_rule",
                            resource: @automation_rule,
                            error: result.error || "Test failed",
                          })
    end
  end

  # === Run (manual triggers only) ===

  def describe_run
    unless @automation_rule.manual_trigger?
      return render_action_error({
                                   action_name: "run_automation_rule",
                                   resource: @automation_rule,
                                   error: "Only manual trigger automations can be run directly",
                                 })
    end

    input_params = @automation_rule.manual_inputs.map do |name, definition|
      {
        name: "inputs.#{name}",
        type: definition["type"] || "string",
        description: definition["label"] || name.humanize,
        optional: true,
        default: definition["default"],
      }
    end

    render_action_description({
                                action_name: "run_automation_rule",
                                resource: @automation_rule,
                                description: "Run this manual automation",
                                params: input_params,
                              })
  end

  def execute_run
    unless @automation_rule.manual_trigger?
      return render_action_error({
                                   action_name: "run_automation_rule",
                                   resource: @automation_rule,
                                   error: "Only manual trigger automations can be run directly",
                                 })
    end

    # Extract and validate inputs from params
    inputs, input_errors = extract_and_validate_inputs(params[:inputs])

    if input_errors.any?
      return render_action_error({
                                   action_name: "run_automation_rule",
                                   resource: @automation_rule,
                                   error: "Invalid inputs: #{input_errors.join(", ")}",
                                 })
    end

    # Build trigger data for manual run
    trigger_data = {
      "inputs" => inputs,
      "triggered_at" => Time.current.iso8601,
      "triggered_by" => @current_user.id,
    }

    # Create the run
    run = AutomationRuleRun.create!(
      tenant: @current_tenant,
      collective: @current_collective,
      automation_rule: @automation_rule,
      trigger_source: "manual",
      trigger_data: trigger_data,
      status: "pending",
    )

    # Execute asynchronously
    AutomationRuleExecutionJob.perform_later(
      automation_rule_run_id: run.id,
      tenant_id: run.tenant_id
    )

    render_action_success({
                            action_name: "run_automation_rule",
                            resource: @automation_rule,
                            result: "Automation run started.",
                            metadata: { run_id: run.id },
                          })
  end

  private

  def build_test_summary(result)
    parts = ["Test completed successfully."]

    if result.actions_executed.any?
      parts << "#{result.actions_executed.size} action(s) executed:"
      result.actions_executed.each_with_index do |action, i|
        action_result = action["result"] || action[:result]
        status = action_result.is_a?(Hash) ? (action_result["success"] || action_result[:success] ? "success" : "failed") : "executed"
        parts << "  #{i + 1}. #{action["type"] || action[:type]}: #{status}"
      end
    end

    parts.join("\n")
  end

  # Extract inputs from params, validate types, and coerce values
  # Returns [validated_inputs, errors]
  def extract_and_validate_inputs(raw_inputs)
    inputs = {}
    errors = []
    input_definitions = @automation_rule.manual_inputs

    return [{}, []] if raw_inputs.blank? || input_definitions.empty?

    # Only permit declared keys
    declared_keys = input_definitions.keys
    permitted = raw_inputs.permit(*declared_keys).to_h

    permitted.each do |key, value|
      definition = input_definitions[key]
      next unless definition.is_a?(Hash)

      declared_type = definition["type"] || "string"

      case declared_type
      when "string"
        inputs[key] = value.to_s
      when "number"
        if value.to_s.match?(/\A-?\d+(\.\d+)?\z/)
          inputs[key] = value.to_s.include?(".") ? value.to_f : value.to_i
        else
          errors << "#{key} must be a number"
        end
      when "boolean"
        if %w[true false 1 0].include?(value.to_s.downcase)
          inputs[key] = %w[true 1].include?(value.to_s.downcase)
        else
          errors << "#{key} must be true or false"
        end
      else
        inputs[key] = value.to_s
      end
    end

    [inputs, errors]
  end

  def require_user
    return if current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.md { render plain: "# Error\n\nYou must be logged in to manage automations.", status: :unauthorized }
    end
  end

  def require_studio_admin
    return if @current_user.collective_member&.is_admin?

    respond_to do |format|
      format.html { redirect_to @current_collective.path, alert: "You must be a studio admin to manage automations." }
      format.json { render json: { error: "Forbidden" }, status: :forbidden }
      format.md { render plain: "# Error\n\nYou must be a studio admin to manage automations.", status: :forbidden }
    end
  end

  def set_sidebar_mode
    @sidebar_mode = "settings"
    @team = @current_collective.team
  end

  def set_automation_rule
    @automation_rule = AutomationRule.tenant_scoped_only
      .where(collective_id: @current_collective.id)
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
    "/studios/#{@current_collective.handle}/settings/automations"
  end

  def automation_path(rule)
    "/studios/#{@current_collective.handle}/settings/automations/#{rule.truncated_id}"
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
