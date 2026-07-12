# typed: false

class CollectivesController < ApplicationController
  include RequiresReverification

  before_action :set_sidebar_mode, only: [:index, :new, :settings, :invite, :join, :backlinks, :views, :view, :members, :pool]
  before_action -> { require_reverification(scope: "collective_archive") }, only: [:archive, :unarchive]

  def index
    @page_title = "Collectives"
    if current_user
      all_collectives = current_user.collectives
        .listable
        .with_heartbeat_for(current_user)
        .where.not(id: @current_tenant.main_collective_id)
        .order(:has_heartbeat, :name)

      if @current_tenant.feature_enabled?("stripe_billing")
        @my_collectives = all_collectives.select { |c| c.created_by_id == current_user.id }
        @member_collectives = all_collectives.reject { |c| c.created_by_id == current_user.id }
      else
        @collectives = all_collectives
      end
    else
      @collectives = []
    end
    respond_to do |format|
      format.html
      format.md
    end
  end

  def redirect_to_workspace
    if current_user.nil?
      redirect_to "/login"
      return
    end

    workspace = current_user.private_workspace
    if workspace
      redirect_to workspace.path
    else
      redirect_to "/collectives", alert: "No workspace found."
    end
  end

  def actions_index
    @page_title = "Actions | Collectives"
    render_actions_index({
      actions: [
        ActionsHelper.action_description("create_collective"),
      ],
    })
  end

  def show
    @page_title = @current_collective.name
    @pinned_items = @current_collective.pinned_items
    @cycle = current_cycle
    @previous_cycle = previous_cycle
    @read_notes = @cycle.read_notes(@current_user)
    @prev_read_notes = @previous_cycle.read_notes(@current_user)
    @unread_notes = @cycle.unread_notes(@current_user)
    @prev_unread_notes = @previous_cycle.unread_notes(@current_user)
    @open_decisions = @cycle.open_decisions
    @closed_decisions = @cycle.closed_decisions
    @prev_decisions = @previous_cycle.decisions_closed_within_cycle
    @open_commitments = @cycle.open_commitments
    @closed_commitments = @cycle.closed_commitments
    @prev_commitments = @previous_cycle.commitments_closed_within_cycle
    @team = @current_collective.team
    @heartbeats = Heartbeat.where_in_cycle(@cycle) - [current_heartbeat]
    unless @current_user.collective_member.dismissed_notices.include?('collective-welcome')
      @current_user.collective_member.dismiss_notice!('collective-welcome')
      if @current_collective.created_by == @current_user
        flash[:notice] = "Welcome to your new collective! [Click here to invite your team](#{@current_collective.url}/invite)"
      else
        flash[:notice] = "Welcome to #{@current_collective.name}! You can start creating notes, decisions, and commitments by clicking the plus icon to the right of the page header."
      end
    end
  end

  def new
    @page_title = 'New Collective'
    @page_description = 'Create a new collective'
  end

  def actions_index_new
    @page_title = 'Actions | New Collective'
    render_actions_index(ActionsHelper.actions_for_route('/collectives/new'))
  end

  def describe_create_collective
    @page_title = 'Create Collective'
    @page_description = 'Create a new collective'
    render_action_description(ActionsHelper.action_description("create_collective"))
  end

  def create_collective
    if (error = collective_type_request_error)
      return render_action_error({
        action_name: "create_collective",
        resource: nil,
        error: error,
      })
    end

    begin
      collective = api_helper.create_collective
      render_action_success({
        action_name: "create_collective",
        resource: collective,
        result: "Collective created successfully.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: "create_collective",
        resource: nil,
        error: e.message,
      })
    end
  end

  def describe_send_heartbeat
    render_action_description(ActionsHelper.action_description("send_heartbeat", resource: @current_collective))
  end

  def send_heartbeat
    return render_action_error({ action_name: 'send_heartbeat', resource: @current_collective, error: 'You must be logged in.', status: :unauthorized }) unless current_user

    if current_heartbeat
      return render_action_error({ action_name: 'send_heartbeat', resource: @current_collective, error: 'Heartbeat already exists for this cycle.', status: :conflict })
    end

    begin
      heartbeat = api_helper.create_heartbeat
      render_action_success({
        action_name: 'send_heartbeat',
        resource: @current_collective,
        result: "Heartbeat sent. You now have access to #{@current_collective.name} for this cycle.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'send_heartbeat',
        resource: @current_collective,
        error: e.message,
      })
    end
  end

  def handle_available
    render json: { available: Collective.handle_available?(params[:handle]) }
  end

  def create
    if (error = collective_type_request_error)
      flash[:alert] = error
      return redirect_to "/collectives/new"
    end

    @collective = api_helper.create_collective
    flash[:notice] = "Collective #{@collective.name} created successfully."
    redirect_to @collective.path
  end

  def settings
    if @current_collective.private_workspace?
      redirect_to @current_collective.path, alert: "Settings are not available for workspaces."
      return
    end

    if can_manage_own_collective_settings?
      @page_title = 'Collective Settings'

      # Proration preview no longer needed here — reactivation is managed on /billing

      # AI agents in this collective (for display) - exclude archived memberships
      @collective_ai_agents = @current_collective.users
        .includes(:tenant_users)
        .joins(:collective_members)
        .where(user_type: 'ai_agent')
        .where(collective_members: { collective_id: @current_collective.id, archived_at: nil })
        .distinct
      # Current user's AI agents that are NOT active members of this collective (for adding)
      user_ai_agent_ids = @current_user.ai_agents.pluck(:id)
      active_collective_ai_agent_ids = @collective_ai_agents.pluck(:id)
      addable_ids = user_ai_agent_ids - active_collective_ai_agent_ids
      @addable_ai_agents = User.where(id: addable_ids).includes(:tenant_users).where(tenant_users: { tenant_id: @current_tenant.id })
      # Funding pool state: the pool, its enrollments, agents on its payroll,
      # and this tenant's agents that could be attached (their principal is
      # actively enrolled).
      if @current_collective.standard? && @current_tenant.feature_enabled?("stripe_billing")
        @funding_pools_enabled = @current_collective.feature_enabled?("funding_pools")
        @funding_pool = @current_collective.funding_pool
        if @funding_pool && !@funding_pool.archived?
          @funded_agents = @funding_pool.funded_agents.order(:name)
          @pool_enrollments = @funding_pool.enrollments.active.includes(:user).to_a
          @current_user_enrolled = @pool_enrollments.any? { |e| e.user_id == @current_user.id }
          enrolled_ids = @pool_enrollments.map(&:user_id)
          @attachable_agents = User.where(user_type: "ai_agent", parent_id: enrolled_ids)
            .includes(:tenant_users).where(tenant_users: { tenant_id: @current_tenant.id })
            .where.not(id: @funded_agents.pluck(:id))
            .order(:name)
        end
      end
      # Automation counts for display
      @enabled_automations_count = @current_collective.automation_rules.where(enabled: true).count
      @total_automations_count = @current_collective.automation_rules.count
      # If the owner started a Stripe Checkout for this collective and
      # navigated back without completing, surface a "Resume checkout"
      # affordance instead of a fresh Upgrade button. Clear the stash once
      # the collective is paid — the webhook handler also clears it via
      # `confirm_collective_upgrade_from_checkout`, but the stash can
      # linger if the user never visits /billing after completing checkout.
      if session[:pending_collective_upgrade] == @current_collective.id && @current_collective.paid_tier?
        session.delete(:pending_collective_upgrade)
      end
      @pending_collective_upgrade_in_session = session[:pending_collective_upgrade] == @current_collective.id
    else
@sidebar_mode = 'minimal'
      return render layout: 'application', html: 'You must be an admin to access collective settings.'
    end
  end

  def update_settings
    if @current_collective.private_workspace?
      return render status: 403, plain: 'Settings cannot be changed for workspaces.'
    end
    if !can_manage_own_collective_settings?
      return render status: 403, plain: '403 Unauthorized'
    end
    if @current_collective.archived?
      flash[:error] = "Cannot update settings for a deactivated collective. Reactivate it on the billing page first."
      return redirect_to "#{@current_collective.path}/settings"
    end
    @current_collective.name = params[:name]
    # @current_collective.handle = params[:handle] if params[:handle]
    @current_collective.description = params[:description]
    @current_collective.timezone = params[:timezone]
    @current_collective.tempo = params[:tempo]
    @current_collective.synchronization_mode = params[:synchronization_mode]
    # Per-member daily draw ceiling (lives on the collective's funding pool).
    # Dollars in the form, cents in the column; blank clears it.
    if params.key?(:member_daily_draw_cap)
      pool = @current_collective.funding_pool
      if pool.nil?
        flash[:error] = "This collective has no funding pool."
        return redirect_to "#{@current_collective.path}/settings"
      end
      begin
        pool.update!(member_daily_draw_cap_cents: MoneyParam.dollars_to_cents(params[:member_daily_draw_cap]))
      rescue ArgumentError
        flash[:error] = "The member daily draw ceiling must be a dollar amount (or blank for no ceiling)."
        return redirect_to "#{@current_collective.path}/settings"
      end
    end
    unless @current_collective.private_workspace?
      @current_collective.settings['all_members_can_invite'] = params[:invitations] == 'all_members'
      @current_collective.settings['any_member_can_represent'] = params[:representation] == 'any_member'
      @current_collective.settings['any_member_can_summarize'] = params[:summarization] == 'any_member'
    end
    unless ENV['SAAS_MODE'] == 'true'
      @current_collective.settings['file_storage_limit'] = (params[:file_storage_limit].to_i * 1.megabyte) if params[:file_storage_limit]
    end

    # Handle feature flags via unified system. Paid feature flags can only
    # be enabled when the collective is on the paid tier — toggle attempts
    # on free collectives are silently ignored so that name/description edits
    # in the same form still go through. The settings UI hides these toggles
    # on free collectives entirely (per Step F).
    FeatureFlagService.all_flags.each do |flag_name|
      param_key = "feature_#{flag_name}"
      next unless params.key?(param_key) || params.key?(flag_name)
      # Operator-managed flags (e.g. funding_pools) are enabled per collective
      # by a platform admin, never from this self-serve form.
      next if FeatureFlagService.operator_managed?(flag_name)

      value = params[param_key] || params[flag_name]
      enabled = value == "true" || value == "1" || value == true
      next if Collective::PAID_FEATURE_FLAGS.include?(flag_name) && enabled && !@current_collective.tier_unlocks_paid_features?

      @current_collective.settings["feature_flags"] ||= {}
      @current_collective.settings["feature_flags"][flag_name] = enabled
    end

    @current_collective.updated_by = @current_user if @current_collective.changed?
    @current_collective.save!

    TrioActivator.reconcile!(@current_collective)

    flash[:notice] = "Settings successfully updated. [Return to collective homepage.](#{@current_collective.url})"
    redirect_to request.referrer
  end

  # GET /collectives/:handle/upgrade
  # Confirmation page shown before charging. Two cases:
  # - Owner already has active billing → show the prorated $X.XX that will
  #   be charged immediately, then a "Confirm" button that POSTs to the
  #   actual upgrade endpoint.
  # - Owner has no billing yet → explain they'll be sent to Stripe Checkout
  #   to enter card details + see the price there.
  # Redirected to settings when the collective can't be upgraded (already
  # paid, main collective, or a non-billing tenant — see collective_upgradeable?).
  def upgrade_preview
    return render status: 403, plain: "Only the collective owner can upgrade." unless @current_user.id == @current_collective.created_by_id
    return redirect_to "#{@current_collective.path}/settings" unless collective_upgradeable?

    @page_title = "Upgrade #{@current_collective.name}"
    @has_active_billing = @current_user.stripe_customer&.active? && @current_user.stripe_customer.stripe_subscription_id.present?
    @proration_amount_cents = StripeService.preview_proration(@current_user) if @has_active_billing
  end

  # POST /collectives/:handle/upgrade
  # Moves a free collective to the paid plan. Owner-only. If the owner has no
  # active Stripe customer, redirects to Stripe Checkout — final confirmation
  # then comes from the checkout.session.completed webhook (which calls
  # confirm_upgrade!). The `session[:pending_collective_upgrade]` stash lets
  # the settings page show a "Resume checkout" affordance if the owner
  # navigates back during checkout.
  def upgrade
    return render status: 403, plain: "Only the collective owner can upgrade." unless @current_user.id == @current_collective.created_by_id

    settings_path = "#{@current_collective.path}/settings"

    # Nothing to upgrade for main collectives, already-paid collectives, or
    # non-billing tenants (all have paid features unlocked already). Redirect
    # rather than fall through to a misleading "is now on the paid plan" flash.
    return redirect_to settings_path unless collective_upgradeable?

    begin
      @current_collective.upgrade!(actor: @current_user)
    rescue Collective::BillingRequired
      checkout_url = StripeCheckoutService.create_session_for_collective_upgrade!(
        user: @current_user,
        collective: @current_collective,
        success_url: billing_show_url + "?checkout_session_id={CHECKOUT_SESSION_ID}&return_to=#{CGI.escape(settings_path)}",
        cancel_url: "#{request.base_url}#{settings_path}",
      )
      session[:pending_collective_upgrade] = @current_collective.id
      return redirect_to checkout_url, allow_other_host: true
    rescue Collective::NotOwner
      return render status: 403, plain: "Only the collective owner can upgrade."
    end

    sync_result = if @current_tenant.feature_enabled?("stripe_billing")
      StripeService.sync_subscription_quantity!(@current_user)
    end
    flash[:notice] = if sync_result && !sync_result.success
      "#{@current_collective.name} is now on the paid plan. Your next invoice will reflect this within 24 hours."
    else
      "#{@current_collective.name} is now on the paid plan."
    end
    redirect_to settings_path
  end

  # POST /collectives/:handle/downgrade
  # Moves a paid or lapsed collective back to free. Owner-only. Actively
  # disables enabled automations, clears paid feature flags, and deactivates
  # the trio agent.
  def downgrade
    return render status: 403, plain: "Only the collective owner can downgrade." unless @current_user.id == @current_collective.created_by_id

    begin
      @current_collective.downgrade!(actor: @current_user)
    rescue Collective::NotOwner
      return render status: 403, plain: "Only the collective owner can downgrade."
    end

    sync_result = if @current_tenant.feature_enabled?("stripe_billing")
      StripeService.sync_subscription_quantity!(@current_user)
    end

    # On sync failure, BillingReconciliationJob (daily) will retry and catch
    # the drift. Tell the customer what they need to know — when the change
    # reflects — without leaking the underlying Stripe error.
    flash[:notice] = if sync_result && !sync_result.success
      "#{@current_collective.name} has been downgraded to the free plan. Your next invoice will reflect this within 24 hours."
    else
      "#{@current_collective.name} has been downgraded to the free plan."
    end

    # Allow callers (e.g. the /billing inventory) to keep the user on their page
    # instead of bouncing to settings. Allowlist to known internal paths to
    # prevent open-redirect via a crafted return_to.
    redirect_to safe_downgrade_return_to(params[:return_to]) || "#{@current_collective.path}/settings"
  end

  # POST /collectives/:handle/archive
  # Owner-only, reverification-gated. Archives the collective, making it
  # inaccessible to all members and stopping any associated billing via the
  # model-level Stripe sync. Refuses to archive the tenant's main collective.
  def archive
    return render status: 403, plain: "Only the collective owner can archive." unless @current_user.id == @current_collective.created_by_id
    if @current_collective.is_main_collective?
      flash[:error] = "The main collective cannot be archived."
      return redirect_to "#{@current_collective.path}/settings"
    end

    sync_result = @current_collective.archive!(actor: @current_user)
    SecurityAuditLog.log_user_action(
      user: @current_user,
      ip: request.remote_ip,
      action: "collective_archived",
      details: { collective_id: @current_collective.id, tenant_id: @current_tenant.id },
    )
    flash[:notice] = if sync_result && !sync_result.success
      "#{@current_collective.name} has been archived and downgraded to the free plan. Your next invoice will reflect this within 24 hours. Reactivate it from its settings page."
    else
      "#{@current_collective.name} has been archived and downgraded to the free plan. Reactivate it from its settings page."
    end
    redirect_to "#{@current_collective.path}/settings"
  end

  # POST /collectives/:handle/unarchive
  # Owner-only, reverification-gated. Reactivates an archived collective.
  # `archive!` returned the tier to free, so unarchiving never resumes billing
  # automatically — the owner must explicitly upgrade if they want paid
  # features back.
  def unarchive
    return render status: 403, plain: "Only the collective owner can reactivate." unless @current_user.id == @current_collective.created_by_id

    @current_collective.unarchive!(actor: @current_user)
    SecurityAuditLog.log_user_action(
      user: @current_user,
      ip: request.remote_ip,
      action: "collective_unarchived",
      details: { collective_id: @current_collective.id, tenant_id: @current_tenant.id },
    )
    flash[:notice] = "#{@current_collective.name} has been reactivated on the free plan."
    redirect_to "#{@current_collective.path}/settings"
  end

  def add_ai_agent
    if @current_collective.private_workspace?
      return render status: 403, json: { error: 'Cannot add agents to a private workspace' }
    end
    unless @current_user.collective_member&.is_admin?
      return render status: 403, json: { error: 'Unauthorized' }
    end
    ai_agent = User.find_by(id: params[:ai_agent_id])
    if ai_agent.nil? || !ai_agent.ai_agent? || ai_agent.parent_id != @current_user.id
      return render status: 403, json: { error: 'You can only add your own AI agents' }
    end
    @current_collective.add_user!(ai_agent)

    respond_to do |format|
      format.json do
        render json: {
          ai_agent_id: ai_agent.id,
          ai_agent_name: ai_agent.display_name,
          ai_agent_path: ai_agent.path,
          parent_name: @current_user.display_name,
          parent_path: @current_user.path,
        }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} has been added to #{@current_collective.name}"
        # Only allow local redirects (paths starting with /)
        return_path = params[:return_to]
        redirect_path = return_path&.start_with?("/") ? return_path : "#{@current_collective.path}/settings"
        redirect_to redirect_path
      end
    end
  end

  def remove_ai_agent
    unless @current_user.collective_member&.is_admin?
      return render status: 403, json: { error: 'Unauthorized' }
    end
    ai_agent = User.find_by(id: params[:ai_agent_id])
    if ai_agent.nil? || !ai_agent.ai_agent?
      return render status: 404, json: { error: 'AI Agent not found' }
    end

    collective_member = CollectiveMember.find_by(collective: @current_collective, user: ai_agent)
    if collective_member.nil? || collective_member.archived?
      return render status: 404, json: { error: 'AI Agent not in this collective' }
    end

    collective_member.archive!
    can_readd = ai_agent.parent_id == @current_user.id

    respond_to do |format|
      format.json do
        render json: {
          ai_agent_id: ai_agent.id,
          ai_agent_name: ai_agent.display_name,
          can_readd: can_readd,
        }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} has been removed from #{@current_collective.name}"
        redirect_to "#{@current_collective.path}/settings"
      end
    end
  end

  # Member-facing pool page: state, roster, and self-serve enroll/withdraw.
  # Admin controls (lifecycle, ceiling, agent roster) live on settings; this
  # page is where plain members consent in and out. Non-members never reach
  # it — the collective-membership boundary bounces them to /join.
  def pool
    @funding_pool = @current_collective.funding_pool
    if @funding_pool.nil?
      flash[:alert] = "This collective has no funding pool."
      return redirect_to @current_collective.path
    end

    @page_title = "Funding Pool"
    @funding_pools_enabled = @current_collective.feature_enabled?("funding_pools")
    @pool_enrollments = @funding_pool.enrollments.active.includes(:user).to_a
    @current_user_enrolled = @current_user && @pool_enrollments.any? { |e| e.user_id == @current_user.id }
    @funded_agents = @funding_pool.funded_agents.order(:name)
    respond_to do |format|
      format.html
      format.md
    end
  end

  def actions_index_pool
    @page_title = "Actions | Funding Pool"
    render_actions_index(ActionsHelper.actions_for_route('/collectives/:collective_handle/pool'))
  end

  # Open a funding pool for this collective (or reopen a closed one): the
  # instrument through which enrolled members fund the collective's agents.
  def create_funding_pool
    unless @current_tenant.feature_enabled?("stripe_billing")
      return render_funded_agent_error(403, 'Funding pools require billing to be enabled for this account')
    end
    unless @current_collective.feature_enabled?("funding_pools")
      return render_funded_agent_error(403, 'Funding pools are not enabled for this collective')
    end
    unless @current_collective.standard?
      return render_funded_agent_error(403, 'Only standard collectives can have a funding pool')
    end
    unless @current_user.collective_member&.is_admin?
      return render_funded_agent_error(403, 'Unauthorized')
    end

    pool = @current_collective.funding_pool
    if pool
      pool.unarchive! if pool.archived?
    else
      FundingPool.create!(collective: @current_collective, created_by: @current_user)
    end

    flash[:notice] = "Funding pool is open. Members can now enroll."
    redirect_to "#{@current_collective.path}/settings"
  end

  # Closing the pool stops all of its spending: attached agents are suspended
  # from their next call (1-to-1 — there is no fallback payer). Enrollments
  # survive as consent records for draws already made.
  def close_funding_pool
    unless @current_user.collective_member&.is_admin?
      return render_funded_agent_error(403, 'Unauthorized')
    end
    pool = @current_collective.funding_pool
    if pool.nil? || pool.archived?
      return render_funded_agent_error(404, 'This collective has no open funding pool')
    end

    pool.archive!
    flash[:notice] = "Funding pool closed. Its agents are suspended until it reopens or they are detached."
    redirect_to "#{@current_collective.path}/settings"
  end

  # Enrollment is the member's own consent to be drawn on — always self-serve,
  # never done by an admin on someone's behalf. Redirects land on the pool
  # page: unlike settings, every member can see it.
  def enroll_in_funding_pool
    unless @current_collective.feature_enabled?("funding_pools")
      return render_funded_agent_error(403, 'Funding pools are not enabled for this collective', redirect_path: pool_page_path)
    end
    pool = @current_collective.funding_pool
    if pool.nil? || pool.archived?
      return render_funded_agent_error(404, 'This collective has no open funding pool', redirect_path: pool_page_path)
    end

    begin
      pool.enroll!(@current_user)
    rescue ActiveRecord::RecordInvalid => e
      return render_funded_agent_error(422, e.record.errors.full_messages.to_sentence, redirect_path: pool_page_path)
    end

    flash[:notice] = "You are enrolled: this collective's funded agents can now draw from your prepaid balance."
    redirect_to pool_page_path
  end

  def withdraw_from_funding_pool
    pool = @current_collective.funding_pool
    enrollment = pool && pool.enrollments.find_by(user_id: @current_user.id)
    if enrollment.nil? || enrollment.archived?
      return render_funded_agent_error(404, 'You are not enrolled in this funding pool', redirect_path: pool_page_path)
    end

    enrollment.withdraw!
    flash[:notice] = "You have withdrawn from the funding pool. You drop out of draws immediately."
    redirect_to pool_page_path
  end

  # Attach an agent to the pool's payroll: its LLM usage draws from enrolled
  # members' balances from the next call on. Admitting an agent spends
  # everyone's money, so it is admin-only; the model validation additionally
  # requires the agent's principal to be actively enrolled.
  def add_funded_agent
    unless @current_collective.feature_enabled?("funding_pools")
      return render_funded_agent_error(403, 'Funding pools are not enabled for this collective')
    end
    pool = @current_collective.funding_pool
    if pool.nil? || pool.archived?
      return render_funded_agent_error(403, 'This collective has no open funding pool')
    end
    unless @current_user.collective_member&.is_admin?
      return render_funded_agent_error(403, 'Unauthorized')
    end
    # Scoped to this tenant's agents: funding only operates where the
    # collective lives (per-call enrollment lookups are tenant-scoped), so an
    # agent from another tenant would attach and then be suspended forever.
    ai_agent = User.where(user_type: "ai_agent")
      .joins(:tenant_users).where(tenant_users: { tenant_id: @current_tenant.id })
      .find_by(id: params[:ai_agent_id])
    if ai_agent.nil?
      return render_funded_agent_error(404, 'AI Agent not found')
    end

    ai_agent.funding_pool = pool
    unless ai_agent.save
      return render_funded_agent_error(422, ai_agent.errors.full_messages.to_sentence)
    end

    respond_to do |format|
      format.json do
        render json: {
          ai_agent_id: ai_agent.id,
          ai_agent_name: ai_agent.display_name,
          ai_agent_path: ai_agent.path,
        }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} is now funded by #{@current_collective.name}"
        redirect_to "#{@current_collective.path}/settings"
      end
    end
  end

  def remove_funded_agent
    unless @current_user.collective_member&.is_admin?
      return render_funded_agent_error(403, 'Unauthorized')
    end
    pool = @current_collective.funding_pool
    ai_agent = User.find_by(id: params[:ai_agent_id])
    if pool.nil? || ai_agent.nil? || ai_agent.funding_pool_id != pool.id
      return render_funded_agent_error(404, 'AI Agent is not funded by this collective')
    end

    ai_agent.update!(funding_pool_id: nil)

    respond_to do |format|
      format.json do
        render json: { ai_agent_id: ai_agent.id, ai_agent_name: ai_agent.display_name }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} is no longer funded by #{@current_collective.name}"
        redirect_to "#{@current_collective.path}/settings"
      end
    end
  end

  def actions_index_settings
    @page_title = "Actions | Collective Settings"
    render_actions_index(ActionsHelper.actions_for_route('/collectives/:collective_handle/settings'))
  end

  def describe_update_collective_settings
    render_action_description(ActionsHelper.action_description("update_collective_settings", resource: @current_collective))
  end

  def update_collective_settings_action
    return render_action_error({ action_name: 'update_collective_settings', resource: @current_collective, error: 'You must be logged in.', status: :unauthorized }) unless current_user

    # Gate paid-feature toggle. ApiHelper only changes file_attachments (via
    # the `file_uploads` param); trio is browser-UI-only. Enabling requires
    # the paid plan; disabling is always allowed (idempotent on free).
    if params.has_key?(:file_uploads)
      files_after = [true, "true", "1"].include?(params[:file_uploads])
      if files_after && !@current_collective.tier_unlocks_paid_features?
        return render_action_error({
          action_name: 'update_collective_settings',
          resource: @current_collective,
          error: Collective::PAID_FEATURE_ERROR,
        })
      end
    end

    begin
      collective = api_helper.update_collective_settings
      render_action_success({
        action_name: 'update_collective_settings',
        resource: collective,
        result: "Collective settings updated successfully.",
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'update_collective_settings',
        resource: @current_collective,
        error: e.message,
      })
    end
  end

  def describe_add_ai_agent_to_collective
    return render status: 403, plain: '403 Unauthorized - Only human accounts can manage AI agents' unless current_user&.human?
    # Get list of addable AI agents for context
    addable_ai_agents = current_user.ai_agents.includes(:tenant_users, :collective_members)
      .where(tenant_users: { tenant_id: @current_tenant.id })
      .reject { |s| s.collectives.include?(@current_collective) }

    # Use dynamic params to include available AI agent IDs
    dynamic_params = [
      { name: 'ai_agent_id', type: 'integer', description: "ID of the AI agent to add. Your available AI agents: #{addable_ai_agents.map { |s| "#{s.id} (#{s.name})" }.join(', ')}" },
    ]
    render_action_description(ActionsHelper.action_description("add_ai_agent_to_collective", resource: @current_collective, params_override: dynamic_params))
  end

  def execute_add_ai_agent_to_collective
    return render_action_error({ action_name: 'add_ai_agent_to_collective', resource: @current_collective, error: 'You must be logged in.', status: :unauthorized }) unless current_user
    return render_action_error({ action_name: 'add_ai_agent_to_collective', resource: @current_collective, error: 'Only human accounts can manage AI agents.', status: :forbidden }) unless current_user.human?

    begin
      ai_agent = User.find(params[:ai_agent_id])
      unless ai_agent.ai_agent? && ai_agent.parent_id == current_user.id
        return render_action_error({
          action_name: 'add_ai_agent_to_collective',
          resource: @current_collective,
          error: 'You can only add your own AI agents.',
        })
      end
      unless current_user.can_add_ai_agent_to_collective?(ai_agent, @current_collective)
        return render_action_error({
          action_name: 'add_ai_agent_to_collective',
          resource: @current_collective,
          error: 'You do not have permission to add AI agents to this collective.',
        })
      end

      @current_collective.add_user!(ai_agent)
      render_action_success({
        action_name: 'add_ai_agent_to_collective',
        resource: @current_collective,
        result: "#{ai_agent.display_name} has been added to #{@current_collective.name}.",
      })
    rescue ActiveRecord::RecordNotFound
      render_action_error({
        action_name: 'add_ai_agent_to_collective',
        resource: @current_collective,
        error: 'AI Agent not found.',
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'add_ai_agent_to_collective',
        resource: @current_collective,
        error: e.message,
      })
    end
  end

  def describe_remove_ai_agent_from_collective
    return render status: 403, plain: '403 Unauthorized - Only human accounts can manage AI agents' unless current_user&.human?
    # Get list of removable AI agents for context
    collective_ai_agents = @current_collective.collective_members.includes(:user)
      .reject(&:archived?)
      .map(&:user)
      .select { |u| u.ai_agent? && u.parent_id == current_user.id }

    # Use dynamic params to include removable AI agent IDs
    dynamic_params = [
      { name: 'ai_agent_id', type: 'integer', description: "ID of the AI agent to remove. Your AI agents in this collective: #{collective_ai_agents.map { |s| "#{s.id} (#{s.name})" }.join(', ')}" },
    ]
    render_action_description(ActionsHelper.action_description("remove_ai_agent_from_collective", resource: @current_collective, params_override: dynamic_params))
  end

  def execute_remove_ai_agent_from_collective
    return render_action_error({ action_name: 'remove_ai_agent_from_collective', resource: @current_collective, error: 'You must be logged in.', status: :unauthorized }) unless current_user
    return render_action_error({ action_name: 'remove_ai_agent_from_collective', resource: @current_collective, error: 'Only human accounts can manage AI agents.', status: :forbidden }) unless current_user.human?

    begin
      ai_agent = User.find(params[:ai_agent_id])
      unless ai_agent.ai_agent? && ai_agent.parent_id == current_user.id
        return render_action_error({
          action_name: 'remove_ai_agent_from_collective',
          resource: @current_collective,
          error: 'You can only remove your own AI agents.',
        })
      end

      collective_member = CollectiveMember.find_by(collective: @current_collective, user: ai_agent)
      if collective_member.nil? || collective_member.archived?
        return render_action_error({
          action_name: 'remove_ai_agent_from_collective',
          resource: @current_collective,
          error: 'AI Agent is not a member of this collective.',
        })
      end

      collective_member.archive!
      render_action_success({
        action_name: 'remove_ai_agent_from_collective',
        resource: @current_collective,
        result: "#{ai_agent.display_name} has been removed from #{@current_collective.name}.",
      })
    rescue ActiveRecord::RecordNotFound
      render_action_error({
        action_name: 'remove_ai_agent_from_collective',
        resource: @current_collective,
        error: 'AI Agent not found.',
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'remove_ai_agent_from_collective',
        resource: @current_collective,
        error: e.message,
      })
    end
  end

  def describe_enroll_in_funding_pool
    render_action_description(ActionsHelper.action_description("enroll_in_funding_pool", resource: @current_collective))
  end

  def execute_enroll_in_funding_pool
    return render_action_error({ action_name: 'enroll_in_funding_pool', resource: @current_collective, error: 'You must be logged in.', status: :unauthorized }) unless current_user
    unless @current_collective.feature_enabled?("funding_pools")
      return render_action_error({
        action_name: 'enroll_in_funding_pool',
        resource: @current_collective,
        error: 'Funding pools are not enabled for this collective.',
        status: :not_found,
      })
    end

    pool = @current_collective.funding_pool
    if pool.nil? || pool.archived?
      return render_action_error({
        action_name: 'enroll_in_funding_pool',
        resource: @current_collective,
        error: 'This collective has no open funding pool.',
        status: :not_found,
      })
    end

    begin
      pool.enroll!(current_user)
      render_action_success({
        action_name: 'enroll_in_funding_pool',
        resource: @current_collective,
        result: "You are enrolled: #{@current_collective.name}'s funded agents can now draw from your prepaid balance.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'enroll_in_funding_pool',
        resource: @current_collective,
        error: e.record.errors.full_messages.to_sentence,
      })
    end
  end

  def describe_withdraw_from_funding_pool
    render_action_description(ActionsHelper.action_description("withdraw_from_funding_pool", resource: @current_collective))
  end

  def execute_withdraw_from_funding_pool
    return render_action_error({ action_name: 'withdraw_from_funding_pool', resource: @current_collective, error: 'You must be logged in.', status: :unauthorized }) unless current_user

    pool = @current_collective.funding_pool
    enrollment = pool && pool.enrollments.find_by(user_id: current_user.id)
    if enrollment.nil? || enrollment.archived?
      return render_action_error({
        action_name: 'withdraw_from_funding_pool',
        resource: @current_collective,
        error: 'You are not enrolled in this funding pool.',
        status: :not_found,
      })
    end

    enrollment.withdraw!
    render_action_success({
      action_name: 'withdraw_from_funding_pool',
      resource: @current_collective,
      result: "You have withdrawn from the funding pool. You drop out of draws immediately.",
    })
  end

  def describe_attach_funded_agent
    render_action_description(ActionsHelper.action_description("attach_funded_agent", resource: @current_collective))
  end

  def execute_attach_funded_agent
    return render_action_error({ action_name: 'attach_funded_agent', resource: @current_collective, error: 'You must be logged in.', status: :unauthorized }) unless current_user
    return render_action_error({ action_name: 'attach_funded_agent', resource: @current_collective, error: 'Only collective admins can attach funded agents.', status: :forbidden }) unless current_user.collective_member&.is_admin?
    unless @current_collective.feature_enabled?("funding_pools")
      return render_action_error({
        action_name: 'attach_funded_agent',
        resource: @current_collective,
        error: 'Funding pools are not enabled for this collective.',
        status: :not_found,
      })
    end

    pool = @current_collective.funding_pool
    if pool.nil? || pool.archived?
      return render_action_error({
        action_name: 'attach_funded_agent',
        resource: @current_collective,
        error: 'This collective has no open funding pool.',
        status: :not_found,
      })
    end

    # Same tenant-scoped lookup as the HTML endpoint: an agent from another
    # tenant would attach and then be suspended forever.
    ai_agent = User.where(user_type: "ai_agent")
      .joins(:tenant_users).where(tenant_users: { tenant_id: @current_tenant.id })
      .find_by(id: params[:ai_agent_id])
    if ai_agent.nil?
      return render_action_error({
        action_name: 'attach_funded_agent',
        resource: @current_collective,
        error: 'AI Agent not found.',
        status: :not_found,
      })
    end

    ai_agent.funding_pool = pool
    if ai_agent.save
      render_action_success({
        action_name: 'attach_funded_agent',
        resource: @current_collective,
        result: "#{ai_agent.display_name} is now funded by #{@current_collective.name}.",
      })
    else
      render_action_error({
        action_name: 'attach_funded_agent',
        resource: @current_collective,
        error: ai_agent.errors.full_messages.to_sentence,
      })
    end
  end

  def describe_detach_funded_agent
    render_action_description(ActionsHelper.action_description("detach_funded_agent", resource: @current_collective))
  end

  def execute_detach_funded_agent
    return render_action_error({ action_name: 'detach_funded_agent', resource: @current_collective, error: 'You must be logged in.', status: :unauthorized }) unless current_user
    return render_action_error({ action_name: 'detach_funded_agent', resource: @current_collective, error: 'Only collective admins can detach funded agents.', status: :forbidden }) unless current_user.collective_member&.is_admin?

    pool = @current_collective.funding_pool
    ai_agent = User.find_by(id: params[:ai_agent_id])
    if pool.nil? || ai_agent.nil? || ai_agent.funding_pool_id != pool.id
      return render_action_error({
        action_name: 'detach_funded_agent',
        resource: @current_collective,
        error: 'AI Agent is not funded by this collective.',
        status: :not_found,
      })
    end

    ai_agent.update!(funding_pool_id: nil)
    render_action_success({
      action_name: 'detach_funded_agent',
      resource: @current_collective,
      result: "#{ai_agent.display_name} is no longer funded by #{@current_collective.name}.",
    })
  end

  def actions_index_join
    @page_title = "Actions | Join Collective"
    render_actions_index(ActionsHelper.actions_for_route('/collectives/:collective_handle/join'))
  end

  def describe_join_collective
    render_action_description(ActionsHelper.action_description("join_collective", resource: @current_collective))
  end

  def join_collective_action
    return render_action_error({ action_name: 'join_collective', resource: @current_collective, error: 'You must be logged in.', status: :unauthorized }) unless current_user

    begin
      invite = Invite.find_by(code: params[:code]) if params[:code]
      invite ||= Invite.find_by(invited_user: current_user, collective: @current_collective)
      api_helper.join_collective(invite: invite)
      render_action_success({
        action_name: 'join_collective',
        resource: @current_collective,
        result: "You have joined #{@current_collective.name}.",
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'join_collective',
        resource: @current_collective,
        error: e.message,
      })
    end
  end

  def members
    @page_title = 'Members'
    @can_manage_members = @current_user&.collective_member&.is_admin? &&
      !@current_collective.private_workspace? &&
      !@current_collective.is_main_collective?
    @manageable_roles = CollectiveMember.valid_roles
  end

  def actions_index_members
    @page_title = "Actions | Members"
    render_actions_index(ActionsHelper.actions_for_route('/collectives/:collective_handle/members'))
  end

  def describe_update_member_roles
    render_action_description(ActionsHelper.action_description("update_member_roles", resource: @current_collective))
  end

  # POST /collectives/:handle/members/actions/update_member_roles
  # Admin-only. Grants or revokes a single role on a member. Runs through the
  # standard action pipeline (path-based capability check + action helpers).
  def execute_update_member_roles
    member = authorize_member_management("update_member_roles")
    return if member == :handled

    role = params[:role].to_s
    unless CollectiveMember.valid_roles.include?(role)
      return render_action_error({ action_name: 'update_member_roles', resource: @current_collective, error: "Invalid role: #{role}." })
    end

    grant = ActiveModel::Type::Boolean.new.cast(params[:grant])

    # The collective owner is permanent (see #execute_remove_member); they must
    # always retain admin so a second admin can never lock them out of their
    # own collective.
    if role == 'admin' && !grant && member.user_id == @current_collective.created_by_id
      return render_action_error({ action_name: 'update_member_roles', resource: @current_collective, error: 'The collective owner must remain an admin.' })
    end

    # Lockout protection: never let the last admin lose the admin role, or
    # there would be no one left who can manage the collective.
    if role == 'admin' && !grant && last_admin?(member)
      return render_action_error({ action_name: 'update_member_roles', resource: @current_collective, error: 'Cannot remove the admin role from the last admin of this collective.' })
    end

    begin
      grant ? member.add_role!(role) : member.remove_role!(role)
    rescue => e
      return render_action_error({ action_name: 'update_member_roles', resource: @current_collective, error: e.message })
    end

    # Notify the member when they gain a role, so they learn about the new
    # standing and who granted it (issue #340). Revocations are silent, and a
    # self-grant (an admin editing their own roles) notifies no one — the
    # dispatcher drops actor == recipient.
    if grant
      EventService.record!(
        event_type: "collective_member.role_granted",
        actor: @current_user,
        subject: member,
        metadata: { "role" => role },
        collective_id: @current_collective.id
      )
    end

    render_action_success({
      action_name: 'update_member_roles',
      resource: @current_collective,
      result: "#{member.user.display_name} #{grant ? 'now has' : 'no longer has'} the #{role} role.",
      redirect_to: "#{@current_collective.path}/members",
    })
  end

  def describe_remove_member
    render_action_description(ActionsHelper.action_description("remove_member", resource: @current_collective))
  end

  # POST /collectives/:handle/members/actions/remove_member
  # Admin-only. Archives a member's collective membership, removing them from
  # the collective. The owner and the acting admin cannot be removed this way.
  def execute_remove_member
    member = authorize_member_management("remove_member")
    return if member == :handled

    if member.user_id == @current_collective.created_by_id
      return render_action_error({ action_name: 'remove_member', resource: @current_collective, error: 'The collective owner cannot be removed.' })
    end
    if member.user_id == @current_user.id
      return render_action_error({ action_name: 'remove_member', resource: @current_collective, error: 'You cannot remove yourself. Use Leave instead.' })
    end

    member.archive!

    render_action_success({
      action_name: 'remove_member',
      resource: @current_collective,
      result: "#{member.user.display_name} has been removed from #{@current_collective.name}.",
      redirect_to: "#{@current_collective.path}/members",
    })
  end

  def invite
    unless @current_user.collective_member.can_invite?
@sidebar_mode = 'minimal'
      return render layout: 'application', html: 'You do not have permission to invite members to this collective.'
    end
    @page_title = 'Invite to Collective'
    @invite = @current_collective.find_or_create_shareable_invite(@current_user)
  end

  def join
    if current_user && current_user.collectives.include?(@current_collective)
      @current_user_is_member = true
      return
    end
    invite = Invite.find_by(code: params[:code]) if params[:code]
    invite ||= Invite.find_by(invited_user: current_user, collective: @current_collective)
    if invite && current_user
      if invite.collective == @current_collective
        @invite = invite
      else
        return render plain: '404 invite code not found', status: 404
      end
    elsif invite && !current_user
      redirect_to "/login?code=#{invite.code}"
    end
  end

  def accept_invite
    if current_user && current_user.collectives.include?(@current_collective)
      # Double-submit or stale tab — they're in; just take them there.
      return redirect_to @current_collective.path
    end
    # Both lookups are collective-scoped (the default scope pins Invite to
    # @current_collective), so a code belonging to another collective is
    # indistinguishable from an unknown one.
    invite = Invite.find_by(code: params[:code]) if params[:code]
    invite ||= Invite.find_by(invited_user: current_user, collective: @current_collective)
    if invite && current_user
      if invite.is_acceptable_by_user?(current_user)
        @current_user.accept_invite!(invite)
        clear_pending_invite! if pending_invite_code == invite.code
        redirect_to @current_collective.path
      else
        # Expired, revoked, or addressed to someone else.
        flash[:alert] = "That invite code is not valid or has expired."
        if @current_tenant.tenant_users.exists?(user: current_user)
          redirect_to "#{@current_collective.path}/join"
        else
          # A non-member GETting /join with no code would be bounced again
          # before rendering, eating the flash — send them straight to the
          # code-entry page, which renders it.
          redirect_to invite_required_path
        end
      end
    elsif invite && !current_user
      redirect_to "/login?#{{ code: invite.code }.to_query}"
    else
      # TODO - check collective settings to see if public join is allowed
      render plain: '404 invite code not found', status: 404
    end
  end

  def leave
  end

  def pinned_items_partial
    @pinned_items = @current_collective.pinned_items
    render partial: 'shared/pinned', locals: { pinned_items: @pinned_items }
  end

  def members_partial
    @team = @current_collective.team
    render partial: 'shared/team', locals: { team: @team }
  end

  def backlinks
    @page_title = 'Backlinks'
    # TODO - make this more efficient
    @backlinks = Link.where(
      tenant_id: @current_tenant.id,
      collective_id: @current_collective.id,
    ).includes(:to_linkable).group_by(&:to_linkable)
    .sort_by { |k, v| -v.count }
    .map { |k, v| [k, v.count] }
  end

  def update_image
    if @current_user.collective_member.is_admin?
      if params[:image].present?
        @current_collective.image = params[:image]
      elsif params[:cropped_image_data].present?
        @current_collective.cropped_image_data = params[:cropped_image_data]
      else
        return render status: 400, plain: '400 Bad Request'
      end
      @current_collective.save!
    end
    redirect_to request.referrer
  end

  def views
    @page_title = 'Views'
  end

  def view
    @cycle = Cycle.new(
      name: params[:cycle] || 'today',
      tenant: @current_tenant,
      collective: @current_collective,
      current_user: @current_user,
      params: {
        filters: params[:filters] || params[:filter],
        sort_by: params[:sort_by],
        group_by: params[:group_by],
      }
    )
    @current_resource = @cycle
    @grouped_rows = @cycle.data_rows
    @filters = params[:filters] || params[:filter]
    @sort_by = params[:sort_by]
    @group_by = params[:group_by]
    @sort_by_options = @cycle.sort_by_options
    @group_by_options = @cycle.group_by_options
    @filter_options = @cycle.filter_options
  end

  # POST /collectives/:collective_handle/deactivate
  private

  # Only this type is user-creatable; chat and private_workspace
  # collectives are minted by their own internal flows.
  USER_CREATABLE_COLLECTIVE_TYPES = ["standard"].freeze

  # The funded-agent actions are called from both the settings page's plain
  # HTML forms and JSON clients; errors must come back in the caller's format.
  def render_funded_agent_error(status, message, redirect_path: nil)
    respond_to do |format|
      format.json { render status: status, json: { error: message } }
      format.html do
        flash[:alert] = message
        redirect_to(redirect_path || "#{@current_collective.path}/settings")
      end
    end
  end

  def pool_page_path
    "#{@current_collective.path}/pool"
  end

  # Returns an error message when the requested collective type may not be
  # created by this user, nil when the request is fine.
  def collective_type_request_error
    requested = params[:collective_type].presence || "standard"
    return "Collective type #{requested.inspect} is not available." unless USER_CREATABLE_COLLECTIVE_TYPES.include?(requested)

    nil
  end

  # Shared guard for the member-management actions. Renders the appropriate
  # action error and returns :handled when the request is not allowed;
  # otherwise returns the (non-archived) CollectiveMember being acted on.
  #
  # The path-based capability check (ActionCapabilityCheck) already runs ahead
  # of this: a capability-restricted actor (an AI agent) reaches here only if it
  # has been granted the member-management capability. This method is the second
  # key — it enforces collective-admin standing and resolves the target member —
  # so an agent must be both capability-granted AND a collective admin to act.
  # True when the current user may manage THIS collective's own settings.
  #
  # Normally that's an admin member. It is also the collective acting as
  # itself: during a collective representation session current_user is the
  # collective's identity user, which has no CollectiveMember row (so the plain
  # is_admin? check would raise on nil). Representing a collective is already a
  # role-gated, reverified, audited action, so the collective may edit its own
  # settings / public profile as itself. Scoped to this collective's own
  # identity — never another collective's.
  def can_manage_own_collective_settings?
    return false unless @current_user

    @current_user.collective_member&.is_admin? ||
      @current_collective.identity_user_id == @current_user.id
  end

  def authorize_member_management(action_name)
    unless @current_user&.collective_member&.is_admin?
      render_action_error({ action_name: action_name, resource: @current_collective, error: 'You must be an admin to manage members.', status: :forbidden })
      return :handled
    end
    if @current_collective.private_workspace? || @current_collective.is_main_collective?
      render_action_error({ action_name: action_name, resource: @current_collective, error: 'Members cannot be managed for this collective.', status: :forbidden })
      return :handled
    end
    # Members are identified by handle (the stable, human-meaningful id the
    # markdown/agent interface exposes), not the internal numeric user id.
    # Handles are tenant-scoped via TenantUser; accept an optional leading "@".
    handle = params[:user_handle].to_s.delete_prefix("@")
    target_user = @current_tenant.tenant_users.find_by(handle: handle)&.user
    member = target_user && CollectiveMember.find_by(
      collective: @current_collective,
      user_id: target_user.id,
      archived_at: nil,
    )
    if member.nil?
      render_action_error({ action_name: action_name, resource: @current_collective, error: 'Member not found.', status: :not_found })
      return :handled
    end
    member
  end

  # True when `member` is an admin and is the only remaining (non-archived)
  # admin of the collective — used to prevent admin lockout.
  def last_admin?(member)
    return false unless member.is_admin?

    @current_collective.collective_members
      .where(archived_at: nil)
      .where_has_role('admin')
      .count <= 1
  end

  # A collective can be upgraded only when billing is actually in effect on
  # the tenant, it isn't the main collective (always free), and it isn't
  # already on the paid tier. Main collectives and collectives on non-billing
  # tenants already have paid features unlocked via
  # Collective#tier_unlocks_paid_features?, so "upgrade" is a no-op for them —
  # guarding here keeps the preview and the POST from showing a misleading
  # success or charging needlessly. A lapsed collective IS upgradeable
  # (paid_tier? is false), which flips it back to paid via the normal flow.
  def collective_upgradeable?
    @current_tenant.feature_enabled?("stripe_billing") &&
      !@current_collective.is_main_collective? &&
      !@current_collective.paid_tier?
  end

  # Allowlist for downgrade's `return_to` param. Only the billing page is
  # supported today — the settings page is the default redirect, so it doesn't
  # need to be listed here. Returning nil falls back to the default.
  def safe_downgrade_return_to(return_to)
    return nil if return_to.blank?
    return billing_show_path if return_to == billing_show_path

    nil
  end

  def set_sidebar_mode
    if action_name.in?(%w[index new])
      @sidebar_mode = 'minimal'
    else
      @sidebar_mode = 'settings'
      @team = @current_collective.team
    end
  end

end
