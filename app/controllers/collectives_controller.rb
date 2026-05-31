# typed: false

class CollectivesController < ApplicationController
  include RequiresReverification

  before_action :set_sidebar_mode, only: [:index, :new, :settings, :invite, :join, :backlinks, :views, :view, :members]
  before_action -> { require_reverification(scope: "collective_archive") }, only: [:archive, :unarchive]

  def index
    @page_title = "Collectives"
    if current_user
      all_collectives = current_user.collectives
        .listable
        .joins(
          "LEFT JOIN heartbeats ON heartbeats.collective_id = collectives.id AND " +
          "heartbeats.user_id = '#{current_user.id}' AND " +
          "heartbeats.expires_at > '#{Time.current}'"
        )
        .select("collectives.*, heartbeats.id IS NOT NULL AS has_heartbeat")
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
    @collective = api_helper.create_collective
    flash[:notice] = "Collective #{@collective.name} created successfully."
    redirect_to @collective.path
  end

  def settings
    if @current_collective.private_workspace?
      redirect_to @current_collective.path, alert: "Settings are not available for workspaces."
      return
    end

    if @current_user.collective_member.is_admin?
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
    if !@current_user.collective_member.is_admin?
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
    unless @current_collective.private_workspace?
      @current_collective.settings['all_members_can_invite'] = params[:invitations] == 'all_members'
      @current_collective.settings['any_member_can_represent'] = params[:representation] == 'any_member'
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
      return render status: 400, text: 'You are already a member of this collective'
    end
    invite = Invite.find_by(code: params[:code]) if params[:code]
    invite ||= Invite.find_by(invited_user: current_user, collective: @current_collective)
    if invite && current_user
      if invite.collective == @current_collective
        @current_user.accept_invite!(invite)
        redirect_to @current_collective.path
      else
        return render plain: '404 invite code not found', status: 404
      end
    elsif invite && !current_user
      redirect_to "/login?code=#{invite.code}"
    else
      # TODO - check collective settings to see if public join is allowed
      return render plain: '404 invite code not found', status: 404
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
