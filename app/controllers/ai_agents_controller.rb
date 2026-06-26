# typed: false

class AiAgentsController < ApplicationController
  include RequiresReverification

  TASK_RUNS_PER_MINUTE = 5

  before_action :set_sidebar_mode,
                only: [:new, :index, :show, :settings, :run_task, :execute_task, :runs, :show_run, :cancel_run, :create, :execute_create_ai_agent, :deactivate,
                       :reactivate,]
  before_action :require_any_ai_agents_enabled, only: [
    :index, :show, :settings, :update_settings,
    :describe_update_ai_agent, :execute_update_ai_agent, :settings_actions_index,
  ]
  before_action :require_internal_ai_agents_enabled, only: [:run_task, :execute_task, :runs, :show_run, :cancel_run]
  before_action :require_flag_for_create_mode, only: [:new, :create, :execute_create_ai_agent]
  before_action :require_billing_for_creation, only: [:new]
  before_action :load_credit_balance_for_agents, only: [:index, :new, :run_task]
  # Token creation is the sensitive action gated here: execute_create_ai_agent
  # can mint a token inline via generate_token=1, and AiAgentConnectController
  # mints one from the agent settings page. Use the same "api_tokens" scope
  # ApiTokensController and AiAgentConnectController use, so a single
  # reverification covers the whole create-and-mint flow.
  before_action -> { require_reverification(scope: "api_tokens") },
                only: [:new, :create, :execute_create_ai_agent]
  before_action :set_ai_agent,
                only: [:show, :settings, :update_settings, :settings_actions_index, :describe_update_ai_agent, :execute_update_ai_agent, :deactivate,
                       :reactivate,]
  before_action :authorize_parent_or_self, only: [:show, :settings, :settings_actions_index]
  before_action :authorize_parent, only: [
    :update_settings, :describe_update_ai_agent, :execute_update_ai_agent,
    :deactivate, :reactivate,
  ]

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

    # Get automation rules for this agent (excluding notification webhooks,
    # which have their own UI on the settings page)
    @automation_rules = AutomationRule.tenant_scoped_only
      .where(ai_agent_id: @ai_agent.id)
      .excluding_notification_webhooks
      .order(created_at: :desc)
      .limit(5)

    # Get recent runs
    @recent_runs = AiAgentTaskRun
      .where(ai_agent: @ai_agent)
      .order(created_at: :desc)
      .limit(5)

    # When arriving here from create-with-token, the plaintext token rides
    # through one flash round-trip. Wrap in a transient struct so the show
    # view's `@token.plaintext_token` / `@token.expires_at` paths work
    # without branching. Refreshing the page clears the flash → secret can
    # only be revealed once. no_store prevents bfcache replay.
    return unless flash[:reveal_token].present?

    @token = Struct.new(:plaintext_token, :expires_at).new(
      flash[:reveal_token],
      Time.iso8601(flash[:reveal_token_expires_at])
    )
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, private"
    response.headers["Pragma"] = "no-cache"
  end

  # POST /ai-agents/:handle/deactivate
  # GET /ai-agents/:handle/settings - Show settings for a specific AI agent
  def settings
    @page_title = "Settings - #{@ai_agent.display_name}"
    @notification_webhook = AutomationRule.tenant_scoped_only.notification_webhook_for(@ai_agent).first if @ai_agent.external_ai_agent?

    # Proration preview no longer needed here — reactivation is managed on /billing

    # Get collectives the agent is a member of
    active_collective_members = @ai_agent.collective_members.reject(&:archived?)
    all_ai_agent_collectives = active_collective_members.map(&:collective)
    @ai_agent_collectives = all_ai_agent_collectives.reject { |s| s == @current_tenant.main_collective || !s.listable? }

    # Get collectives the agent can be added to (collectives where current user can invite)
    invitable_collectives = @current_user.collective_members.includes(:collective).select(&:can_invite?).map(&:collective)
    @available_collectives = (invitable_collectives - all_ai_agent_collectives).reject { |s| s == @current_tenant.main_collective || !s.listable? }
  end

  # POST /ai-agents/:handle/settings - Update settings for a specific AI agent
  def update_settings
    if @ai_agent.archived?
      flash[:error] = "Cannot update settings for a deactivated agent. Reactivate it on the billing page first."
      return redirect_to ai_agent_settings_path(@ai_agent.handle)
    end

    name = params[:name]
    new_handle = params[:new_handle]
    identity_prompt = params[:identity_prompt]
    mode = params[:mode]
    model = params[:model]
    capabilities = params[:capabilities]
    # Capture before any handle change — a failed update leaves the rejected
    # handle in the in-memory tenant_user, which would otherwise feed a bad
    # value into the redirect path below.
    original_handle = @ai_agent.handle

    # Update name if provided
    @ai_agent.name = name if name.present?

    # Update handle if provided (via tenant_user). A taken or reserved handle
    # fails validation — surface it as a friendly error rather than a 500.
    if new_handle.present?
      tu = @ai_agent.tenant_user
      if tu && !tu.update(handle: new_handle)
        flash[:error] = tu.errors.full_messages.to_sentence
        return redirect_to ai_agent_settings_path(original_handle)
      end
    end

    # Update agent configuration
    config = @ai_agent.agent_configuration || {}
    config["identity_prompt"] = identity_prompt if identity_prompt.present?
    config["mode"] = mode if mode.present?
    config["model"] = model if mode == "internal" && model.present?
    if params.key?(:capabilities)
      caps = Array(capabilities).compact_blank
      config["capabilities"] = caps & CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS
    end
    config["visibility_zones"] = CapabilityCheck.sanitize_zones(params[:visibility_zones]) if params.key?(:visibility_zones)
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
    return render status: :not_found, plain: "404 Not Found" unless @ai_agent.internal_ai_agent?

    @page_title = "Run Task - #{@ai_agent.display_name}"
    @max_steps_default = AiAgentTaskRun::DEFAULT_MAX_STEPS
  end

  # POST /ai-agents/:handle/run - Execute the task
  def execute_task
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can run AI agent tasks" unless current_user&.human?

    @ai_agent = find_ai_agent_by_handle
    return render status: :not_found, plain: "404 Not Found" unless @ai_agent
    return render status: :not_found, plain: "404 Not Found" unless @ai_agent.internal_ai_agent?

    begin
      enforce_rate_limit!(
        scope: "agent_task_runs",
        key: [current_user.id, @ai_agent.id],
        limit: TASK_RUNS_PER_MINUTE,
        period: 1.minute
      )
    rescue RateLimits::Exceeded
      respond_to do |format|
        format.html do
          flash[:alert] = "You're starting tasks too quickly. Please wait a moment and try again."
          redirect_to ai_agent_run_task_path(@ai_agent.handle)
        end
        format.json do
          render status: :too_many_requests, json: { error: "rate_limited", message: "Too many task runs. Please wait a minute and try again." }
        end
      end
      return
    end

    if current_tenant.feature_enabled?("stripe_billing")
      billing_customer = @ai_agent.billing_customer
      unless billing_customer&.active?
        session[:billing_return_to] = ai_agent_run_task_path(@ai_agent.handle)
        flash[:notice] = "Set up billing before running AI agent tasks"
        return redirect_to "/billing"
      end
    end

    max_steps = params[:max_steps].present? ? params[:max_steps].to_i : nil

    @task_run = AiAgentTaskRun.create_queued(
      ai_agent: @ai_agent,
      tenant: current_tenant,
      initiated_by: current_user,
      task: params[:task],
      max_steps: max_steps
    )

    # Dispatch to the agent-runner service via Redis stream
    AgentRunnerDispatchService.dispatch(@task_run)

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
        @task_run.agent_session_steps.load # eager load for the timeline partial
        @page_title = "Task Run - #{@ai_agent.display_name}"
      end
      format.md do
        @created_resources = @task_run.ai_agent_task_run_resources
          .includes(:resource_collective)
          .order(:created_at)
        @task_run.agent_session_steps.load # eager load for the timeline partial
        @page_title = "Task Run - #{@ai_agent.display_name}"
      end
      format.json do
        steps = @task_run.agent_session_steps.map(&:to_step_hash)

        render json: {
          status: @task_run.status,
          steps_count: steps.length,
          steps: steps,
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
      flash[:alert] = "Can only cancel queued or running tasks"
      return redirect_to ai_agent_run_path(@ai_agent.handle, @task_run.id)
    end

    @task_run.update!(
      status: "cancelled",
      success: false,
      error: "Cancelled by user",
      completed_at: Time.current
    )

    # No re-enqueue needed: every queued task is already published to the
    # agent-runner stream at creation time. agent-runner's per-agent lock
    # means sibling queued tasks will be picked up as the current one finishes.

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

    @proration_amount_cents = StripeService.preview_proration(current_user) if current_tenant.feature_enabled?("stripe_billing")

    respond_to do |format|
      format.html
      format.md
    end
  end

  # NOTE: This action has no route. Agent creation goes through execute_create_ai_agent.
  def create
    return render status: :forbidden, plain: "403 Unauthorized - Only human accounts can create AI agents" unless current_user&.human?

    @ai_agent = api_helper.create_ai_agent
    # Only generate token for external AI agents
    if @ai_agent.external_ai_agent? && ["true", "1"].include?(params[:generate_token])
      @token = api_helper.generate_token(@ai_agent, mcp_only: extract_mcp_only_for_generated_token)
    end
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
                                   status: :forbidden,
                                 })
    end

    if current_user.requires_stripe_billing?(current_tenant)
      respond_to do |format|
        format.md do
          return render_action_error({
                                       action_name: "create_ai_agent",
                                       resource: @current_user,
                                       error: "Billing is not set up. Please set up billing at /billing before creating AI agents.",
                                     })
        end
        format.any do
          session[:billing_return_to] = new_ai_agent_path
          flash[:notice] = "Set up billing to create AI agents"
          return redirect_to "/billing"
        end
      end
    end

    # Require billing confirmation when stripe_billing is enabled.
    # Admins (sys_admin / app_admin) are billing-exempt — they never see the
    # confirm-billing checkbox in the UI, so don't reject them for not
    # checking it.
    if current_tenant.feature_enabled?("stripe_billing") &&
       !current_user.app_admin? && !current_user.sys_admin? &&
       params[:confirm_billing] != "1"
      respond_to do |format|
        format.md do
          return render_action_error({
                                       action_name: "create_ai_agent",
                                       resource: @current_user,
                                       error: "You must confirm that you understand each AI agent costs $3/month added to your subscription.",
                                     })
        end
        format.any do
          flash[:alert] = "You must confirm the billing charge to create an AI agent."
          return redirect_to new_ai_agent_path
        end
      end
    end

    begin
      @ai_agent = api_helper.create_ai_agent
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # An explicitly-chosen handle that's already taken (or reserved) fails:
      # the uniqueness validation raises RecordInvalid, with the DB index as
      # the race backstop (RecordNotUnique). A blank handle auto-generates and
      # never reaches here. Re-raise any unrelated validation failure rather
      # than mislabeling it as a handle problem.
      raise if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.key?(:handle)

      msg = "That handle is already taken. Please choose a different one."
      respond_to do |format|
        format.md do
          return render_action_error({
                                       action_name: "create_ai_agent",
                                       resource: @current_user,
                                       error: msg,
                                     })
        end
        format.any do
          flash[:alert] = msg
          return redirect_to new_ai_agent_path
        end
      end
    end
    charged_cents = nil
    if current_tenant.feature_enabled?("stripe_billing")
      assign_billing_customer!(@ai_agent)
      # Decide whether the new agent needs to wait for billing setup.
      # Use requires_stripe_billing? rather than stripe_customer.active?
      # so admins (who are billing-exempt — billable_quantity is always 0)
      # don't get their agents spuriously pending-flagged.
      if current_user.requires_stripe_billing?(current_tenant)
        @ai_agent.update!(pending_billing_setup: true)
      elsif current_user.stripe_customer&.active?
        result = StripeService.sync_subscription_quantity!(current_user)
        if result.success
          charged_cents = result.charged_cents
        else
          # Sync failed — mark agent pending so it doesn't run unbilled
          @ai_agent.update!(pending_billing_setup: true)
        end
      end
      # Else: user doesn't need billing (admin / fully exempt) — leave the agent active.
    end
    # Only generate token for external AI agents (not for pending agents)
    if !@ai_agent.pending_billing_setup? && @ai_agent.external_ai_agent? && [true, "true", "1"].include?(params[:generate_token])
      @token = api_helper.generate_token(@ai_agent, mcp_only: extract_mcp_only_for_generated_token)
    end

    notice = if @ai_agent.pending_billing_setup?
               "AI Agent #{@ai_agent.display_name} created. Set up billing to activate it."
             elsif @token
               "AI Agent #{@ai_agent.display_name} created. Save the token value now — you will not be able to see it again."
             elsif charged_cents && charged_cents > 0
               "AI Agent #{@ai_agent.display_name} created successfully. You were charged $#{format("%.2f",
                                                                                                    charged_cents / 100.0)} (prorated for the current billing period)."
             else
               "AI Agent #{@ai_agent.display_name} created successfully."
             end

    # When a token was just generated, the plaintext value exists only in
    # memory on this @token (hashed at rest). For HTML we redirect to the
    # canonical show URL and carry the plaintext through a flash round-trip
    # in the encrypted session cookie, so the URL bar lands on the agent's
    # show page instead of the POST endpoint. Markdown stays inline since
    # the API has no URL bar to confuse.
    if @token
      if request.format.md?
        @page_title = @ai_agent.display_name
        @automation_rules = AutomationRule.tenant_scoped_only
          .where(ai_agent_id: @ai_agent.id)
          .excluding_notification_webhooks
          .order(created_at: :desc).limit(5)
        @recent_runs = AiAgentTaskRun
          .where(ai_agent: @ai_agent).order(created_at: :desc).limit(5)
        flash.now[:notice] = notice
        render "show"
        return
      end
      redirect_to ai_agent_path(@ai_agent.handle),
                  notice: notice,
                  flash: { reveal_token: @token.plaintext_token, reveal_token_expires_at: @token.expires_at.iso8601 }
      return
    end

    flash[:notice] = notice
    redirect_path = @ai_agent.pending_billing_setup? ? "/billing" : ai_agent_path(@ai_agent.handle)
    respond_to do |format|
      format.md do
        render_action_success({
                                action_name: "create_ai_agent",
                                resource: @ai_agent,
                                result: notice,
                                redirect_to: redirect_path,
                              })
      end
      format.html { redirect_to redirect_path }
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

  def load_credit_balance_for_agents
    return unless current_user&.human?
    return unless current_tenant&.feature_enabled?("stripe_billing")
    return unless ENV.fetch("LLM_GATEWAY_MODE", "litellm") == "stripe_gateway"

    sc = current_user.stripe_customer
    return unless sc&.active?

    @credit_balance_cents = StripeService.get_credit_balance(sc)
  end

  def require_billing_for_creation
    return unless current_user&.human?
    return unless current_user.requires_stripe_billing?(current_tenant)

    session[:billing_return_to] = new_ai_agent_path
    flash[:notice] = "Set up billing to create AI agents"
    redirect_to "/billing"
  end

  def require_any_ai_agents_enabled
    return if @current_tenant&.any_ai_agents_enabled?

    render_ai_agents_disabled
  end

  def require_internal_ai_agents_enabled
    return if @current_tenant&.internal_ai_agents_enabled?

    render_ai_agents_disabled
  end

  def require_flag_for_create_mode
    mode = ["internal", "external"].include?(params[:mode]) ? params[:mode] : "external"
    return if mode == "internal" && @current_tenant&.internal_ai_agents_enabled?
    return if mode == "external" && @current_tenant&.external_ai_agents_enabled?

    render_ai_agents_disabled
  end

  def render_ai_agents_disabled
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
    render status: :not_found, plain: "404 Not Found" unless @ai_agent&.ai_agent?
  end

  def authorize_parent
    render status: :forbidden, plain: "403 Unauthorized" unless @ai_agent.parent_id == current_user&.id
  end

  def authorize_parent_or_self
    return if @ai_agent.parent_id == current_user&.id
    return if @ai_agent == current_user

    render status: :forbidden, plain: "403 Unauthorized"
  end

  def find_ai_agent_by_handle
    current_user.ai_agents
      .joins(:tenant_users)
      .where(tenant_users: { tenant_id: current_tenant.id, handle: params[:handle] })
      .first
  end

  def assign_billing_customer!(ai_agent)
    stripe_customer = current_user.stripe_customer
    ai_agent.update!(stripe_customer_id: stripe_customer.id) if stripe_customer
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

  # Default true (MCP-only) unless the form explicitly passes "0"/false.
  def extract_mcp_only_for_generated_token
    return true unless params.key?(:mcp_only)

    [true, "true", "1"].include?(params[:mcp_only])
  end
end
