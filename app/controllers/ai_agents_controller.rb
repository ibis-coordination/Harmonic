# typed: false

class AiAgentsController < ApplicationController
  before_action :set_sidebar_mode, only: [:new, :index, :show, :settings, :run_task, :execute_task, :runs, :show_run, :cancel_run, :create, :execute_create_ai_agent]
  before_action :require_ai_agents_enabled, only: [:index, :show, :settings, :run_task, :execute_task, :runs, :show_run, :cancel_run]
  before_action :set_ai_agent, only: [:show, :settings, :update_settings, :settings_actions_index, :describe_update_ai_agent, :execute_update_ai_agent]
  before_action :authorize_parent, only: [:show, :settings, :update_settings, :settings_actions_index, :describe_update_ai_agent, :execute_update_ai_agent]

  # GET /ai-agents - List all AI agents owned by current user
  def index
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can view AI agents" unless current_user&.human?

    @page_title = "My AI Agents"
    ai_agents = current_user.ai_agents
      .joins(:tenant_users)
      .where(tenant_users: { tenant_id: current_tenant.id })
      .includes(:tenant_users, :collective_members)

    # Load the most relevant run for each AI agent
    # Priority: running > queued > most recent completed/failed
    # Limit to 10 runs per agent to avoid loading too much data
    ai_agent_ids = ai_agents.map(&:id)
    all_runs = AiAgentTaskRun
      .where(ai_agent_id: ai_agent_ids)
      .where("created_at > ?", 30.days.ago)
      .order(created_at: :desc)
      .limit(ai_agent_ids.size * 10)

    @latest_runs_by_ai_agent = {}
    all_runs.group_by(&:ai_agent_id).each do |agent_id, runs|
      # Prefer running, then queued, then most recent by creation time
      @latest_runs_by_ai_agent[agent_id] =
        runs.find { |r| r.status == "running" } ||
        runs.find { |r| r.status == "queued" } ||
        runs.first
    end

    # Calculate total estimated costs per agent (all time)
    @total_costs_by_ai_agent = AiAgentTaskRun
      .where(ai_agent_id: ai_agent_ids)
      .completed
      .group(:ai_agent_id)
      .sum(:estimated_cost_usd)

    # Sort AI agents by most recent run first, then by created_at for those without runs
    @ai_agents = ai_agents.sort_by do |s|
      run = @latest_runs_by_ai_agent[s.id]
      run ? -run.created_at.to_i : -s.created_at.to_i
    end
  end

  # GET /ai-agents/:handle - Show a specific AI agent
  def show
    @page_title = @ai_agent.display_name

    # Get automation rules for this agent
    @automation_rules = AutomationRule.tenant_scoped_only
      .where(ai_agent_id: @ai_agent.id)
      .order(created_at: :desc)
      .limit(5)

    # Get recent runs
    @recent_runs = AiAgentTaskRun
      .where(ai_agent: @ai_agent)
      .order(created_at: :desc)
      .limit(5)
  end

  # GET /ai-agents/:handle/settings - Show settings for a specific AI agent
  def settings
    @page_title = "Settings - #{@ai_agent.display_name}"

    # Get studios the agent is a member of
    active_collective_members = @ai_agent.collective_members.reject(&:archived?)
    all_ai_agent_studios = active_collective_members.map(&:collective)
    @ai_agent_studios = all_ai_agent_studios.reject { |s| s == @current_tenant.main_collective }

    # Get studios the agent can be added to (studios where current user can invite)
    invitable_studios = @current_user.collective_members.includes(:collective).select(&:can_invite?).map(&:collective)
    @available_studios = (invitable_studios - all_ai_agent_studios).reject { |s| s == @current_tenant.main_collective }
  end

  # POST /ai-agents/:handle/settings - Update settings for a specific AI agent
  def update_settings
    name = params[:name]
    new_handle = params[:new_handle]
    identity_prompt = params[:identity_prompt]
    mode = params[:mode]
    model = params[:model]
    capabilities = params[:capabilities]

    # Update name if provided
    @ai_agent.name = name if name.present?

    # Update handle if provided (via tenant_user)
    if new_handle.present?
      tu = @ai_agent.tenant_user
      tu.update!(handle: new_handle) if tu
    end

    # Update agent configuration
    config = @ai_agent.agent_configuration || {}
    config["identity_prompt"] = identity_prompt if identity_prompt.present?
    config["mode"] = mode if mode.present?
    config["model"] = model if mode == "internal" && model.present?
    config["capabilities"] = capabilities if capabilities.present?
    @ai_agent.agent_configuration = config

    if @ai_agent.save
      flash[:notice] = "Settings updated successfully"
      redirect_to ai_agent_settings_path(@ai_agent.handle)
    else
      flash[:error] = @ai_agent.errors.full_messages.join(", ")
      redirect_to ai_agent_settings_path(@ai_agent.handle)
    end
  end

  # GET /ai-agents/:handle/run - Show task form for specific AI agent
  def run_task
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can run AI agent tasks" unless current_user&.human?

    @ai_agent = find_ai_agent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @ai_agent

    @page_title = "Run Task - #{@ai_agent.display_name}"
    @max_steps_default = AiAgentTaskRun::DEFAULT_MAX_STEPS
  end

  # POST /ai-agents/:handle/run - Execute the task
  def execute_task
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can run AI agent tasks" unless current_user&.human?

    @ai_agent = find_ai_agent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @ai_agent

    max_steps = params[:max_steps].present? ? params[:max_steps].to_i : nil

    @task_run = AiAgentTaskRun.create_queued(
      ai_agent: @ai_agent,
      tenant: current_tenant,
      initiated_by: current_user,
      task: params[:task],
      max_steps: max_steps
    )

    # Enqueue background job to process the task
    AgentQueueProcessorJob.perform_later(
      ai_agent_id: @ai_agent.id,
      tenant_id: current_tenant.id
    )

    respond_to do |format|
      format.html { redirect_to ai_agent_run_path(@ai_agent.handle, @task_run.id) }
      format.json { render json: { id: @task_run.id, status: @task_run.status } }
    end
  end

  # GET /ai-agents/:handle/runs - List past task runs
  def runs
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can view task runs" unless current_user&.human?

    @ai_agent = find_ai_agent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @ai_agent

    @page_title = "Task Runs - #{@ai_agent.display_name}"
    @task_runs = AiAgentTaskRun.where(ai_agent: @ai_agent).recent
  end

  # GET /ai-agents/:handle/runs/:run_id - Show a specific task run
  def show_run
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can view task runs" unless current_user&.human?

    @ai_agent = find_ai_agent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @ai_agent

    @task_run = AiAgentTaskRun.find_by(id: params[:run_id], ai_agent: @ai_agent)
    return render status: :not_found, plain: "404 Not Found" unless @task_run

    respond_to do |format|
      format.html do
        @created_resources = @task_run.ai_agent_task_run_resources
          .includes(:resource_collective)
          .order(:created_at)
        @page_title = "Task Run - #{@ai_agent.display_name}"
      end
      format.md do
        @created_resources = @task_run.ai_agent_task_run_resources
          .includes(:resource_collective)
          .order(:created_at)
        @page_title = "Task Run - #{@ai_agent.display_name}"
      end
      format.json do
        render json: {
          status: @task_run.status,
          steps_count: @task_run.steps_count,
          steps: @task_run.steps_data,
          final_message: @task_run.final_message,
          error: @task_run.error,
        }
      end
    end
  end

  # POST /ai-agents/:handle/runs/:run_id/cancel - Cancel a running/queued task
  def cancel_run
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can cancel task runs" unless current_user&.human?

    @ai_agent = find_ai_agent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @ai_agent

    @task_run = AiAgentTaskRun.find_by(id: params[:run_id], ai_agent: @ai_agent)
    return render status: :not_found, plain: "404 Not Found" unless @task_run

    unless @task_run.status.in?(["queued", "running"])
      flash[:error] = "Can only cancel queued or running tasks"
      return redirect_to ai_agent_run_path(@ai_agent.handle, @task_run.id)
    end

    @task_run.update!(
      status: "cancelled",
      success: false,
      error: "Cancelled by user",
      completed_at: Time.current
    )

    # Trigger job to pick up any remaining queued tasks
    AgentQueueProcessorJob.perform_later(
      ai_agent_id: @ai_agent.id,
      tenant_id: current_tenant.id
    )

    respond_to do |format|
      format.html do
        flash[:notice] = "Task run cancelled"
        redirect_to ai_agent_run_path(@ai_agent.handle, @task_run.id)
      end
      format.json { render json: { status: @task_run.status } }
    end
  end

  def new
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can create AI agents" unless current_user&.human?

    respond_to do |format|
      format.html
      format.md
    end
  end

  def create
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can create AI agents" unless current_user&.human?

    @ai_agent = api_helper.create_ai_agent
    # Only generate token for external AI agents
    @token = api_helper.generate_token(@ai_agent) if @ai_agent.external_ai_agent? && ["true", "1"].include?(params[:generate_token])
    flash.now[:notice] = "AI Agent #{@ai_agent.display_name} created successfully."

    # Redirect to new agent show page
    redirect_to ai_agent_path(@ai_agent.handle)
  end

  def update; end

  def destroy; end

  # Markdown API actions

  def actions_index
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can create AI agents" unless current_user&.human?

    @page_title = "Actions | New AI Agent"
    render_actions_index(ActionsHelper.actions_for_route("/ai-agents/new"))
  end

  def describe_create_ai_agent
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can create AI agents" unless current_user&.human?

    render_action_description(ActionsHelper.action_description("create_ai_agent", resource: @current_user))
  end

  def execute_create_ai_agent
    unless current_user&.human?
      return render_action_error({
                                   action_name: "create_ai_agent",
                                   resource: @current_user,
                                   error: "Only human accounts can create AI agents.",
                                 })
    end
    @ai_agent = api_helper.create_ai_agent
    # Only generate token for external AI agents
    @token = api_helper.generate_token(@ai_agent) if @ai_agent.external_ai_agent? && [true, "true", "1"].include?(params[:generate_token])

    flash.now[:notice] = "AI Agent #{@ai_agent.display_name} created successfully."
    respond_to do |format|
      format.md do
        render_action_success({
          action_name: "create_ai_agent",
          resource: @ai_agent,
          result: "AI Agent '#{@ai_agent.display_name}' created successfully",
          redirect_to: "/ai-agents/#{@ai_agent.handle}",
        })
      end
      format.html { redirect_to ai_agent_path(@ai_agent.handle) }
    end
  end

  # Settings actions (markdown API)
  def settings_actions_index
    @page_title = "Actions | Settings - #{@ai_agent.display_name}"
    render_actions_index(ActionsHelper.actions_for_route("/ai-agents/:handle/settings"))
  end

  def describe_update_ai_agent
    render_action_description(ActionsHelper.action_description("update_profile", resource: @ai_agent))
  end

  def execute_update_ai_agent
    name = params[:name]
    new_handle = params[:new_handle]
    identity_prompt = params[:identity_prompt]

    # Update name if provided
    @ai_agent.name = name if name.present?

    # Update handle if provided (via tenant_user)
    if new_handle.present?
      tu = @ai_agent.tenant_user
      tu.update!(handle: new_handle) if tu
    end

    # Update agent configuration
    if identity_prompt.present?
      config = @ai_agent.agent_configuration || {}
      config["identity_prompt"] = identity_prompt
      @ai_agent.agent_configuration = config
    end

    if @ai_agent.save
      render_action_success({
        action_name: "update_profile",
        resource: @ai_agent,
        result: "AI Agent settings updated successfully",
        redirect_to: "/ai-agents/#{@ai_agent.handle}/settings",
      })
    else
      render_action_error({
        action_name: "update_profile",
        resource: @ai_agent,
        error: @ai_agent.errors.full_messages.join(", "),
      })
    end
  end

  def current_resource_model
    User
  end

  private

  def require_ai_agents_enabled
    return if @current_tenant&.ai_agents_enabled?

    respond_to do |format|
      format.html { render status: :forbidden, plain: "403 Forbidden - AI Agents feature is not enabled for this tenant" }
      format.json { render status: :forbidden, json: { error: "AI Agents feature is not enabled for this tenant" } }
      format.md { render status: :forbidden, plain: "403 Forbidden - AI Agents feature is not enabled for this tenant" }
    end
  end

  def set_sidebar_mode
    @sidebar_mode = "minimal"
  end

  def set_ai_agent
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: :not_found, plain: "404 Not Found" if tu.nil?

    @ai_agent = tu.user
    return render status: :not_found, plain: "404 Not Found" unless @ai_agent&.ai_agent?
  end

  def authorize_parent
    return render status: :forbidden, plain: "403 Unauthorized" unless @ai_agent.parent_id == current_user&.id
  end

  def find_ai_agent_by_handle
    current_user.ai_agents
      .joins(:tenant_users)
      .where(tenant_users: { tenant_id: current_tenant.id, handle: params[:handle] })
      .first
  end

  def serialize_result(result)
    {
      success: result.success,
      final_message: result.final_message,
      error: result.error,
      steps: result.steps.map do |step|
        {
          type: step.type,
          detail: step.detail,
          timestamp: step.timestamp.iso8601,
        }
      end,
    }
  end
end
