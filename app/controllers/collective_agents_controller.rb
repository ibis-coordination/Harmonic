# typed: false

# The collective agents page: what runs in this collective, who pays for it,
# and whether it can run. Member-visible; admin controls conditional. The page
# owns the explicit Trio toggle — the trio feature flag stays the single
# source of truth, with PersonaActivator reconciling the ensemble to it.
#
# Private workspaces have no agents page: the workspace assistant is managed
# from the owner's user settings instead.
class CollectiveAgentsController < ApplicationController
  before_action :set_sidebar_mode, only: [:show]
  before_action :reject_private_workspaces

  def show
    @page_title = "Agents"
    @is_agents_admin = @current_user&.collective_member&.is_admin? || false
    @billing_tenant = @current_tenant.feature_enabled?("stripe_billing")
    @plan_gated = @billing_tenant && !@current_collective.tier_unlocks_paid_features?
    @trio_offered = FeatureFlagService.tenant_enabled?(@current_tenant, "trio")
    @trio_enabled = @current_collective.trio_enabled?
    @personas = @current_collective.persona_users
    @funding_pool = @current_collective.funding_pool
    @pool_open = @funding_pool.present? && !@funding_pool.archived?
    # Personas are pool-funded only, so enabled-without-an-open-pool means
    # they cannot run. Only meaningful where billing exists at all.
    @trio_cannot_run = @billing_tenant && @trio_enabled && !@pool_open
    @pool_enrolled_count = @pool_open ? @funding_pool.enrollments.active.count : 0
    @pool_page_available = @current_collective.pool_page_available?
    @member_agents = @current_collective.users
      .joins(:collective_members)
      .where(user_type: "ai_agent")
      .where(collective_members: { collective_id: @current_collective.id, archived_at: nil })
      .distinct
      .order(:name)
    respond_to do |format|
      format.html
      format.md
    end
  end

  # Every agents action lives here, so the conditional actions are evaluated
  # for this viewer instead of being left to the page footer.
  def actions_index
    @page_title = "Actions | Agents"
    route_info = ActionsHelper.actions_for_route("/collectives/:collective_handle/agents") || {}
    context = { user: @current_user, collective: @current_collective, tenant: @current_tenant }
    conditional = (route_info[:conditional_actions] || []).select do |conditional_action|
      conditional_action[:condition].call(context)
    rescue StandardError
      false
    end
    conditional = conditional.map do |conditional_action|
      definition = ActionsHelper.action_definition(conditional_action[:name]) || {}
      { name: conditional_action[:name], params_string: definition[:params_string], description: definition[:description] }
    end
    render_actions_index({ actions: (route_info[:actions] || []) + conditional })
  end

  # The explicit Trio toggle. Enabling needs the tenant to offer Trio and the
  # tier to unlock paid features; disabling is always available to admins, so
  # a lapsed collective can still turn the ensemble off.
  def set_trio_enabled
    return render_agents_error(403, "Unauthorized") unless @current_user&.collective_member&.is_admin?

    enabled = params[:enabled].to_s == "true"
    if enabled
      return render_agents_error(403, "Trio is not available on this account.") unless FeatureFlagService.tenant_enabled?(@current_tenant, "trio")
      return render_agents_error(403, Collective::PAID_FEATURE_ERROR) unless @current_collective.tier_unlocks_paid_features?
    end

    @current_collective.set_feature_flag!("trio", enabled)
    PersonaActivator.reconcile!(@current_collective)
    flash[:notice] = if enabled
                       "Trio is enabled — its personas have joined #{@current_collective.name}."
                     else
                       "Trio is disabled — its personas have been deactivated."
                     end
    redirect_to agents_page_path
  end

  def describe_set_trio_enabled
    render_action_description(ActionsHelper.action_description("set_trio_enabled", resource: @current_collective))
  end

  def execute_set_trio_enabled
    unless current_user
      return render_action_error({ action_name: "set_trio_enabled", resource: @current_collective, error: "You must be logged in.",
                                   status: :unauthorized, })
    end
    unless current_user.collective_member&.is_admin?
      return render_action_error({ action_name: "set_trio_enabled", resource: @current_collective,
                                   error: "Only collective admins can enable or disable Trio.", status: :forbidden, })
    end
    unless ["true", "false"].include?(params[:enabled].to_s)
      return render_action_error({ action_name: "set_trio_enabled", resource: @current_collective,
                                   error: 'enabled must be "true" or "false".', })
    end

    enabled = params[:enabled].to_s == "true"
    if enabled
      unless FeatureFlagService.tenant_enabled?(@current_tenant, "trio")
        return render_action_error({ action_name: "set_trio_enabled", resource: @current_collective,
                                     error: "Trio is not available on this account.", status: :forbidden, })
      end
      unless @current_collective.tier_unlocks_paid_features?
        return render_action_error({ action_name: "set_trio_enabled", resource: @current_collective,
                                     error: Collective::PAID_FEATURE_ERROR, status: :forbidden, })
      end
    end

    @current_collective.set_feature_flag!("trio", enabled)
    PersonaActivator.reconcile!(@current_collective)
    result = if enabled
               "Trio is enabled in #{@current_collective.name}: its personas are members now. " \
                 "On billing accounts they need an open funding pool to run."
             else
               "Trio is disabled in #{@current_collective.name}; its personas have been deactivated."
             end
    render_action_success({ action_name: "set_trio_enabled", resource: @current_collective, result: result })
  end

  private

  def reject_private_workspaces
    return unless @current_collective.private_workspace?

    respond_to do |format|
      format.json { render status: :not_found, json: { error: "Private workspaces have no agents page." } }
      format.md { render status: :not_found, plain: "Private workspaces have no agents page." }
      format.html { redirect_to @current_collective.path }
    end
  end

  def render_agents_error(status, message)
    respond_to do |format|
      format.json { render status: status, json: { error: message } }
      format.html do
        flash[:alert] = message
        redirect_to agents_page_path
      end
    end
  end

  def agents_page_path
    "#{@current_collective.path}/agents"
  end

  def set_sidebar_mode
    @sidebar_mode = "settings"
    @team = @current_collective.team
  end
end
