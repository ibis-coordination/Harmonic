# typed: false

class SubagentsController < ApplicationController
  layout "pulse", only: [:new, :index, :run_task, :execute_task, :runs, :show_run, :create, :execute_create_subagent]
  before_action :verify_current_user_path, except: [:index, :run_task, :execute_task, :runs, :show_run]
  before_action :set_sidebar_mode, only: [:new, :index, :run_task, :execute_task, :runs, :show_run, :create, :execute_create_subagent]
  before_action :require_subagents_enabled, only: [:index, :run_task, :execute_task, :runs, :show_run]

  # GET /subagents - List all subagents owned by current user
  def index
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can view subagents" unless current_user&.person?

    @page_title = "My Subagents"
    subagents = current_user.subagents
      .joins(:tenant_users)
      .where(tenant_users: { tenant_id: current_tenant.id })
      .includes(:tenant_users, :superagent_members)

    # Load latest run for each subagent
    subagent_ids = subagents.map(&:id)
    latest_runs = SubagentTaskRun
      .where(subagent_id: subagent_ids)
      .select("DISTINCT ON (subagent_id) *")
      .order("subagent_id, created_at DESC")
    @latest_runs_by_subagent = latest_runs.index_by(&:subagent_id)

    # Sort subagents by most recent run first, then by created_at for those without runs
    @subagents = subagents.sort_by do |s|
      run = @latest_runs_by_subagent[s.id]
      run ? -run.created_at.to_i : -s.created_at.to_i
    end
  end

  # GET /subagents/:id/run - Show task form for specific subagent
  def run_task
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can run subagent tasks" unless current_user&.person?

    @subagent = find_subagent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @subagent

    @page_title = "Run Task - #{@subagent.display_name}"
    @max_steps_default = SubagentTaskRun::DEFAULT_MAX_STEPS
  end

  # POST /subagents/:id/run - Execute the task
  def execute_task
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can run subagent tasks" unless current_user&.person?

    @subagent = find_subagent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @subagent

    @task_run = SubagentTaskRun.create!(
      tenant: current_tenant,
      subagent: @subagent,
      initiated_by: current_user,
      task: params[:task],
      max_steps: (params[:max_steps] || SubagentTaskRun::DEFAULT_MAX_STEPS).to_i,
      status: "running",
      started_at: Time.current
    )

    navigator = AgentNavigator.new(
      user: @subagent,
      tenant: current_tenant,
      superagent: current_superagent
    )

    # Set task run context for resource tracking during synchronous execution
    saved_task_run_id = SubagentTaskRun.current_id
    SubagentTaskRun.current_id = @task_run.id

    begin
      result = navigator.run(
        task: params[:task],
        max_steps: @task_run.max_steps
      )

      @task_run.update!(
        status: result.success ? "completed" : "failed",
        success: result.success,
        final_message: result.final_message,
        error: result.error,
        steps_count: result.steps.count,
        steps_data: result.steps.map { |s| { type: s.type, detail: s.detail, timestamp: s.timestamp.iso8601 } },
        completed_at: Time.current
      )
    ensure
      # Restore previous context (or clear if none)
      SubagentTaskRun.current_id = saved_task_run_id
    end

    respond_to do |format|
      format.html { redirect_to subagent_run_path(@subagent.handle, @task_run.id) }
      format.json { render json: serialize_result(result) }
    end
  end

  # GET /subagents/:handle/runs - List past task runs
  def runs
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can view task runs" unless current_user&.person?

    @subagent = find_subagent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @subagent

    @page_title = "Task Runs - #{@subagent.display_name}"
    @task_runs = SubagentTaskRun.where(subagent: @subagent).recent
  end

  # GET /subagents/:handle/runs/:run_id - Show a specific task run
  def show_run
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can view task runs" unless current_user&.person?

    @subagent = find_subagent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @subagent

    @task_run = SubagentTaskRun.find_by(id: params[:run_id], subagent: @subagent)
    return render status: :not_found, plain: "404 Not Found" unless @task_run

    respond_to do |format|
      format.html do
        @created_resources = @task_run.subagent_task_run_resources
          .includes(:resource_superagent)
          .order(:created_at)
        @page_title = "Task Run - #{@subagent.display_name}"
      end
      format.md do
        @created_resources = @task_run.subagent_task_run_resources
          .includes(:resource_superagent)
          .order(:created_at)
        @page_title = "Task Run - #{@subagent.display_name}"
      end
      format.json do
        render json: { status: @task_run.status }
      end
    end
  end

  def new
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can create subagents" unless current_user&.person?

    respond_to do |format|
      format.html
      format.md
    end
  end

  def create
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can create subagents" unless current_user&.person?

    @subagent = api_helper.create_subagent
    # Only generate token for external subagents
    if @subagent.external_subagent? && ["true", "1"].include?(params[:generate_token])
      @token = api_helper.generate_token(@subagent)
    end
    flash.now[:notice] = "Subagent #{@subagent.display_name} created successfully."
    render :show
  end

  def update; end

  def destroy; end

  # Markdown API actions

  def actions_index
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can create subagents" unless current_user&.person?

    @page_title = "Actions | New Subagent"
    render_actions_index(ActionsHelper.actions_for_route("/u/:handle/settings/subagents/new"))
  end

  def describe_create_subagent
    return render status: :forbidden, plain: "403 Unauthorized - Only person accounts can create subagents" unless current_user&.person?

    render_action_description(ActionsHelper.action_description("create_subagent", resource: @current_user))
  end

  def execute_create_subagent
    unless current_user&.person?
      return render_action_error({
                                   action_name: "create_subagent",
                                   resource: @current_user,
                                   error: "Only person accounts can create subagents.",
                                 })
    end
    @subagent = api_helper.create_subagent
    # Only generate token for external subagents
    if @subagent.external_subagent? && [true, "true", "1"].include?(params[:generate_token])
      @token = api_helper.generate_token(@subagent)
    end

    flash.now[:notice] = "Subagent #{@subagent.display_name} created successfully."
    respond_to do |format|
      format.md { render "show" }
      format.html { render "show" }
    end
  end

  def current_resource_model
    User
  end

  private

  def require_subagents_enabled
    return if @current_tenant&.subagents_enabled?

    respond_to do |format|
      format.html { render status: :forbidden, plain: "403 Forbidden - Subagents feature is not enabled for this tenant" }
      format.json { render status: :forbidden, json: { error: "Subagents feature is not enabled for this tenant" } }
      format.md { render status: :forbidden, plain: "403 Forbidden - Subagents feature is not enabled for this tenant" }
    end
  end

  def set_sidebar_mode
    @sidebar_mode = "minimal"
  end

  def verify_current_user_path
    handle = params[:handle]
    return if handle.nil?

    tu = current_tenant.tenant_users.find_by(handle: handle)
    return render status: :not_found, plain: "404 Not Found" if tu.nil?

    render status: :forbidden, plain: "403 Unauthorized" unless tu.user == current_user
  end

  def find_subagent_by_handle
    current_user.subagents
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
