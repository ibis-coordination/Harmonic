class StudiosController < ApplicationController

  def show
    @page_title = @current_studio.name
    @pinned_items = @current_studio.pinned_items
    # @open_items = @current_studio.open_items
    # @recently_closed_items = @current_studio.recently_closed_items
    @backlinks = @current_studio.backlink_leaderboard
    @team = @current_studio.team
    @cycle = current_cycle
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

  def handle_available
    render json: { available: Studio.handle_available?(params[:handle]) }
  end

  def create
    ActiveRecord::Base.transaction do
      @studio = Studio.create!(
        name: params[:name],
        handle: params[:handle],
        description: params[:description],
        created_by: @current_user,
        timezone: params[:timezone],
        tempo: params[:tempo],
        synchronization_mode: params[:synchronization_mode],
      )
      @studio.add_user!(@current_user, roles: ['admin', 'representative'])
      @studio.create_welcome_note!
    end
    redirect_to @studio.path
  end

  def settings
    if @current_user.studio_user.is_admin?
      @page_title = 'Studio Settings'
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
