# typed: false

class StudiosController < ApplicationController

  def show
    return render 'shared/404' unless @current_studio.studio_type == 'studio'
    @page_title = @current_studio.name
    @pinned_items = @current_studio.pinned_items
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
    @team = @current_studio.team
    @heartbeats = Heartbeat.where_in_cycle(@cycle) - [current_heartbeat]
    unless @current_user.studio_user.dismissed_notices.include?('studio-welcome')
      @current_user.studio_user.dismiss_notice!('studio-welcome')
      if @current_studio.created_by == @current_user
        flash[:notice] = "Welcome to your new studio! [Click here to invite your team](#{@current_studio.url}/invite)"
      else
        flash[:notice] = "Welcome to #{@current_studio.name}! You can start creating notes, decisions, and commitments by clicking the plus icon to the right of the page header."
      end
    end
  end

  def new
    @page_title = 'New Studio'
    @page_description = 'Create a new studio'
  end

  def actions_index_new
    @page_title = 'Actions | New Studio'
    render_actions_index(ActionsHelper.actions_for_route('/studios/new'))
  end

  def describe_create_studio
    @page_title = 'Create Studio'
    @page_description = 'Create a new studio'
    render_action_description({
      action_name: 'create_studio',
      resource: nil,
      description: 'Create a new studio',
      params: [{
        name: 'name',
        description: 'The name of the studio',
        type: 'string',
      }, {
        name: 'handle',
        description: 'The handle of the studio (used in the URL)',
        type: 'string',
      }, {
        name: 'description',
        description: 'A description of the studio that will appear on the studio homepage',
        type: 'string',
      }, {
        name: 'timezone',
        description: 'The timezone of the studio',
        type: 'string',
      }, {
        name: 'tempo',
        description: 'The tempo of the studio. "daily", "weekly", or "monthly"',
        type: 'string',
      }, {
        name: 'synchronization_mode',
        description: 'The synchronization mode of the studio. "improv" or "orchestra"',
        type: 'string',
      }, {
        name: 'invitations',
        description: 'Who can invite new members: "all_members" or "only_admins" (optional)',
        type: 'string',
      }, {
        name: 'representation',
        description: 'Who can represent the studio: "any_member" or "only_representatives" (optional)',
        type: 'string',
      }, {
        name: 'file_uploads',
        description: 'Whether file attachments are allowed (optional)',
        type: 'boolean',
      }, {
        name: 'api_enabled',
        description: 'Whether API access is allowed for this studio (optional)',
        type: 'boolean',
      }]
    })
  end

  def create_studio
    begin
      studio = api_helper.create_studio
      render_action_success({
        action_name: 'create_studio',
        resource: studio,
        result: 'Studio created successfully.',
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'create_studio',
        resource: nil,
        error: e.message,
      })
    end
  end

  def describe_send_heartbeat
    render_action_description({
      action_name: 'send_heartbeat',
      resource: @current_studio,
      description: 'Send a heartbeat to confirm your presence in the studio for this cycle',
      params: [],
    })
  end

  def send_heartbeat
    return render_action_error({ action_name: 'send_heartbeat', resource: @current_studio, error: 'You must be logged in.' }) unless current_user

    if current_heartbeat
      return render_action_error({ action_name: 'send_heartbeat', resource: @current_studio, error: 'Heartbeat already exists for this cycle.' })
    end

    begin
      heartbeat = api_helper.create_heartbeat
      render_action_success({
        action_name: 'send_heartbeat',
        resource: @current_studio,
        result: "Heartbeat sent. You now have access to #{@current_studio.name} for this cycle.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'send_heartbeat',
        resource: @current_studio,
        error: e.message,
      })
    end
  end

  def handle_available
    render json: { available: Studio.handle_available?(params[:handle]) }
  end

  def create
    @studio = api_helper.create_studio
    redirect_to @studio.path
  end

  def settings
    if @current_user.studio_user.is_admin?
      @page_title = 'Studio Settings'
      # Subagents in this studio (for display) - exclude archived memberships
      @studio_subagents = @current_studio.users
        .includes(:tenant_users)
        .joins(:studio_users)
        .where(user_type: 'subagent')
        .where(studio_users: { studio_id: @current_studio.id, archived_at: nil })
        .distinct
      # Current user's subagents that are NOT active members of this studio (for adding)
      user_subagent_ids = @current_user.subagents.pluck(:id)
      active_studio_subagent_ids = @studio_subagents.pluck(:id)
      addable_ids = user_subagent_ids - active_studio_subagent_ids
      @addable_subagents = User.where(id: addable_ids).includes(:tenant_users).where(tenant_users: { tenant_id: @current_tenant.id })
    else
      return render layout: 'application', html: 'You must be an admin to access studio settings.'
    end
  end

  def update_settings
    if !@current_user.studio_user.is_admin?
      return render status: 403, plain: '403 Unauthorized'
    end
    @current_studio.name = params[:name]
    # @current_studio.handle = params[:handle] if params[:handle]
    @current_studio.description = params[:description]
    @current_studio.timezone = params[:timezone]
    @current_studio.tempo = params[:tempo]
    @current_studio.synchronization_mode = params[:synchronization_mode]
    @current_studio.settings['all_members_can_invite'] = params[:invitations] == 'all_members'
    @current_studio.settings['any_member_can_represent'] = params[:representation] == 'any_member'
    @current_studio.settings['allow_file_uploads'] = params[:allow_file_uploads] == 'true' || params[:allow_file_uploads] == '1'
    @current_studio.settings['api_enabled'] = params[:api_enabled] == 'true' || params[:api_enabled] == '1'
    unless ENV['SAAS_MODE'] == 'true'
      @current_studio.settings['file_storage_limit'] = (params[:file_storage_limit].to_i * 1.megabyte) if params[:file_storage_limit]
    end
    @current_studio.updated_by = @current_user if @current_studio.changed?
    @current_studio.save!
    flash[:notice] = "Settings successfully updated. [Return to studio homepage.](#{@current_studio.url})"
    redirect_to request.referrer
  end

  def add_subagent
    unless @current_user.studio_user&.is_admin?
      return render status: 403, json: { error: 'Unauthorized' }
    end
    subagent = User.find_by(id: params[:subagent_id])
    if subagent.nil? || !subagent.subagent? || subagent.parent_id != @current_user.id
      return render status: 403, json: { error: 'You can only add your own subagents' }
    end
    @current_studio.add_user!(subagent)

    respond_to do |format|
      format.json do
        render json: {
          subagent_id: subagent.id,
          subagent_name: subagent.display_name,
          subagent_path: subagent.path,
          parent_name: @current_user.display_name,
          parent_path: @current_user.path,
        }
      end
      format.html do
        flash[:notice] = "#{subagent.display_name} has been added to #{@current_studio.name}"
        redirect_to "#{@current_studio.path}/settings"
      end
    end
  end

  def remove_subagent
    unless @current_user.studio_user&.is_admin?
      return render status: 403, json: { error: 'Unauthorized' }
    end
    subagent = User.find_by(id: params[:subagent_id])
    if subagent.nil? || !subagent.subagent?
      return render status: 404, json: { error: 'Subagent not found' }
    end

    studio_user = StudioUser.find_by(studio: @current_studio, user: subagent)
    if studio_user.nil? || studio_user.archived?
      return render status: 404, json: { error: 'Subagent not in this studio' }
    end

    studio_user.archive!
    can_readd = subagent.parent_id == @current_user.id

    respond_to do |format|
      format.json do
        render json: {
          subagent_id: subagent.id,
          subagent_name: subagent.display_name,
          can_readd: can_readd,
        }
      end
      format.html do
        flash[:notice] = "#{subagent.display_name} has been removed from #{@current_studio.name}"
        redirect_to "#{@current_studio.path}/settings"
      end
    end
  end

  def actions_index_settings
    @page_title = "Actions | Studio Settings"
    render_actions_index(ActionsHelper.actions_for_route('/studios/:studio_handle/settings'))
  end

  def describe_update_studio_settings
    render_action_description({
      action_name: 'update_studio_settings',
      resource: @current_studio,
      description: 'Update studio settings',
      params: [
        { name: 'name', type: 'string', description: 'The name of the studio' },
        { name: 'description', type: 'string', description: 'A description of the studio' },
        { name: 'timezone', type: 'string', description: 'The timezone of the studio' },
        { name: 'tempo', type: 'string', description: 'The tempo of the studio: "daily", "weekly", or "monthly"' },
        { name: 'synchronization_mode', type: 'string', description: 'The synchronization mode: "improv" or "orchestra"' },
        { name: 'invitations', type: 'string', description: 'Who can invite new members: "all_members" or "only_admins"' },
        { name: 'representation', type: 'string', description: 'Who can represent the studio: "any_member" or "only_representatives"' },
        { name: 'file_uploads', type: 'boolean', description: 'Whether file attachments are allowed' },
        { name: 'api_enabled', type: 'boolean', description: 'Whether API access is allowed (not changeable via API - use HTML UI to modify)' },
      ],
    })
  end

  def update_studio_settings_action
    return render_action_error({ action_name: 'update_studio_settings', resource: @current_studio, error: 'You must be logged in.' }) unless current_user

    begin
      studio = api_helper.update_studio_settings
      render_action_success({
        action_name: 'update_studio_settings',
        resource: studio,
        result: "Studio settings updated successfully.",
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'update_studio_settings',
        resource: @current_studio,
        error: e.message,
      })
    end
  end

  def actions_index_join
    @page_title = "Actions | Join Studio"
    render_actions_index(ActionsHelper.actions_for_route('/studios/:studio_handle/join'))
  end

  def describe_join_studio
    render_action_description({
      action_name: 'join_studio',
      resource: @current_studio,
      description: 'Join the studio',
      params: [
        { name: 'code', type: 'string', required: false, description: 'Invite code (optional for scenes)' },
      ],
    })
  end

  def join_studio_action
    return render_action_error({ action_name: 'join_studio', resource: @current_studio, error: 'You must be logged in.' }) unless current_user

    begin
      invite = StudioInvite.find_by(code: params[:code]) if params[:code]
      invite ||= StudioInvite.find_by(invited_user: current_user, studio: @current_studio)
      api_helper.join_studio(invite: invite)
      render_action_success({
        action_name: 'join_studio',
        resource: @current_studio,
        result: "You have joined #{@current_studio.name}.",
      })
    rescue StandardError => e
      render_action_error({
        action_name: 'join_studio',
        resource: @current_studio,
        error: e.message,
      })
    end
  end

  def team
    @page_title = 'Studio Team'
  end

  def invite
    unless @current_user.studio_user.can_invite?
      return render layout: 'application', html: 'You do not have permission to invite members to this studio.'
    end
    @page_title = 'Invite to Studio'
    @invite = @current_studio.find_or_create_shareable_invite(@current_user)
  end

  def join
    if current_user && current_user.studios.include?(@current_studio)
      @current_user_is_member = true
      return
    end
    invite = StudioInvite.find_by(code: params[:code]) if params[:code]
    invite ||= StudioInvite.find_by(invited_user: current_user, studio: @current_studio)
    if invite && current_user
      if invite.studio == @current_studio
        @invite = invite
      else
        return render plain: '404 invite code not found', status: 404
      end
    elsif invite && !current_user
      redirect_to "/login?code=#{invite.code}"
    end
  end

  def accept_invite
    if current_user && current_user.studios.include?(@current_studio)
      return render status: 400, text: 'You are already a member of this studio'
    elsif current_user && @current_studio.is_scene? && !params[:code]
      @current_studio.add_user!(current_user)
      return redirect_to @current_studio.path
    end
    invite = StudioInvite.find_by(code: params[:code]) if params[:code]
    invite ||= StudioInvite.find_by(invited_user: current_user, studio: @current_studio)
    if invite && current_user
      if invite.studio == @current_studio
        @current_user.accept_invite!(invite)
        redirect_to @current_studio.path
      else
        return render plain: '404 invite code not found', status: 404
      end
    elsif invite && !current_user
      redirect_to "/login?code=#{invite.code}"
    else
      # TODO - check studio settings to see if public join is allowed
      return render plain: '404 invite code not found', status: 404
    end
  end

  def leave
  end

  def pinned_items_partial
    @pinned_items = @current_studio.pinned_items
    render partial: 'shared/pinned', locals: { pinned_items: @pinned_items }
  end

  def team_partial
    @team = @current_studio.team
    render partial: 'shared/team', locals: { team: @team }
  end

  def backlinks
    @page_title = 'Backlinks'
    # TODO - make this more efficient
    @backlinks = Link.where(
      tenant_id: @current_tenant.id,
      studio_id: @current_studio.id,
    ).includes(:to_linkable).group_by(&:to_linkable)
    .sort_by { |k, v| -v.count }
    .map { |k, v| [k, v.count] }
  end

  def update_image
    if @current_user.studio_user.is_admin?
      if params[:image].present?
        @current_studio.image = params[:image]
      elsif params[:cropped_image_data].present?
        @current_studio.cropped_image_data = params[:cropped_image_data]
      else
        return render status: 400, plain: '400 Bad Request'
      end
      @current_studio.save!
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
      studio: @current_studio,
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

end
