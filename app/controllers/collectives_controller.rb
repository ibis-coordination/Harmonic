# typed: false

class CollectivesController < ApplicationController
  before_action :set_sidebar_mode, only: [:index, :new, :settings, :invite, :join, :backlinks, :views, :view, :members]

  def index
    @page_title = "Collectives"
    if current_user
      all_collectives = current_user.collectives
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

    if current_tenant.feature_enabled?("stripe_billing") && current_user&.human?
      @proration_amount_cents = StripeService.preview_proration(current_user)
    end
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
    if requires_collective_billing_confirmation?
      return render_action_error({
        action_name: "create_collective",
        resource: nil,
        error: "You must confirm that you understand each collective costs $3/month added to your subscription. Include confirm_billing: \"1\" to authorize.",
      })
    end

    begin
      collective = api_helper.create_collective
      if current_tenant.feature_enabled?("stripe_billing")
        StripeService.sync_subscription_quantity!(current_user)
      end
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
    return render_action_error({ action_name: 'send_heartbeat', resource: @current_collective, error: 'You must be logged in.' }) unless current_user

    if current_heartbeat
      return render_action_error({ action_name: 'send_heartbeat', resource: @current_collective, error: 'Heartbeat already exists for this cycle.' })
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
    if requires_collective_billing_confirmation?
      flash[:error] = "You must confirm the billing charge to create a collective."
      return redirect_to "/collectives/new"
    end

    @collective = api_helper.create_collective
    charged_cents = nil
    if current_tenant.feature_enabled?("stripe_billing")
      if !current_user.stripe_customer&.active?
        @collective.update!(pending_billing_setup: true)
      else
        result = StripeService.sync_subscription_quantity!(current_user)
        if result == :error
          @collective.update!(pending_billing_setup: true)
        else
          charged_cents = result
        end
      end
    end
    notice = if @collective.pending_billing_setup?
      "Collective #{@collective.name} created. Set up billing to activate it."
    elsif charged_cents && charged_cents > 0
      "Collective #{@collective.name} created successfully. You were charged $#{format("%.2f", charged_cents / 100.0)} (prorated for the current billing period)."
    else
      "Collective #{@collective.name} created successfully."
    end
    flash[:notice] = notice
    redirect_to @collective.pending_billing_setup? ? "/billing" : @collective.path
  end

  def settings
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
    else
@sidebar_mode = 'minimal'
      return render layout: 'application', html: 'You must be an admin to access collective settings.'
    end
  end

  def update_settings
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
    @current_collective.settings['all_members_can_invite'] = params[:invitations] == 'all_members'
    @current_collective.settings['any_member_can_represent'] = params[:representation] == 'any_member'
    unless ENV['SAAS_MODE'] == 'true'
      @current_collective.settings['file_storage_limit'] = (params[:file_storage_limit].to_i * 1.megabyte) if params[:file_storage_limit]
    end

    # Handle feature flags via unified system
    FeatureFlagService.all_flags.each do |flag_name|
      param_key = "feature_#{flag_name}"
      if params.key?(param_key) || params.key?(flag_name)
        # Accept both feature_api and api (legacy) param names
        value = params[param_key] || params[flag_name]
        enabled = value == "true" || value == "1" || value == true
        @current_collective.settings["feature_flags"] ||= {}
        @current_collective.settings["feature_flags"][flag_name] = enabled
      end
    end

    @current_collective.updated_by = @current_user if @current_collective.changed?
    @current_collective.save!
    flash[:notice] = "Settings successfully updated. [Return to collective homepage.](#{@current_collective.url})"
    redirect_to request.referrer
  end

  def add_ai_agent
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
    return render_action_error({ action_name: 'update_collective_settings', resource: @current_collective, error: 'You must be logged in.' }) unless current_user

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
    return render_action_error({ action_name: 'add_ai_agent_to_collective', resource: @current_collective, error: 'You must be logged in.' }) unless current_user
    return render_action_error({ action_name: 'add_ai_agent_to_collective', resource: @current_collective, error: 'Only human accounts can manage AI agents.' }) unless current_user.human?

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
    return render_action_error({ action_name: 'remove_ai_agent_from_collective', resource: @current_collective, error: 'You must be logged in.' }) unless current_user
    return render_action_error({ action_name: 'remove_ai_agent_from_collective', resource: @current_collective, error: 'Only human accounts can manage AI agents.' }) unless current_user.human?

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
    return render_action_error({ action_name: 'join_collective', resource: @current_collective, error: 'You must be logged in.' }) unless current_user

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

  def requires_collective_billing_confirmation?
    current_tenant.feature_enabled?("stripe_billing") &&
      current_user&.human? &&
      params[:confirm_billing] != "1"
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
