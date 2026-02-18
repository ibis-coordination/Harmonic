# typed: false

class UsersController < ApplicationController
  def index
    @page_title = 'Users'
    @sidebar_mode = 'minimal'
    @users = current_tenant.tenant_users
  end

  # Redirect /settings to /u/:handle/settings
  def redirect_to_settings
    redirect_to "#{current_user.path}/settings"
  end

  # Redirect /settings/webhooks to /u/:handle/settings/webhooks
  def redirect_to_settings_webhooks
    redirect_to "#{current_user.path}/settings/webhooks"
  end

  def show
    @sidebar_mode = 'minimal'
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404' if tu.nil?
    @showing_user = tu.user
    @showing_user.tenant_user = tu
    @page_title = @showing_user.display_name
    if params[:collective_handle]
      # Showing user in a specific collective
      sm = @showing_user.collective_members.where(collective: current_collective).first
      return render '404' if sm.nil?
      @showing_user.collective_member = sm
      @common_studios = [current_collective]
      @additional_common_studio_count = (
        current_user.collectives & @showing_user.collectives - [current_tenant.main_collective]
      ).count - 1
    else
      # Showing user at the tenant level, so we want to show all common collectives between the current user and the showing user
      @common_studios = current_user.collectives & @showing_user.collectives - [current_tenant.main_collective]
      @additional_common_studio_count = 0
    end

    # Compute counts of common studios and scenes for profile display
    if @current_user != @showing_user
      all_common = current_user.collectives & @showing_user.collectives - [current_tenant.main_collective]
      @common_studio_count = all_common.count { |s| s.collective_type == "studio" }
      @common_scene_count = all_common.count { |s| s.collective_type == "scene" }
    else
      @common_studio_count = 0
      @common_scene_count = 0
    end
    # Load AI agent count for human users
    if @showing_user.human?
      @ai_agent_count = @showing_user.ai_agents
        .joins(:tenant_users)
        .where(tenant_users: { tenant_id: current_tenant.id })
        .count
    end

    # Load proximity connections for the profile being viewed
    load_proximity_connections

    respond_to do |format|
      format.html
      format.md
    end
  end

  def settings
    @sidebar_mode = 'minimal'
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404', status: 404 if tu.nil?
    @settings_user = tu.user
    return render plain: '403 Unauthorized', status: 403 unless current_user.can_edit?(@settings_user)

    @settings_user.tenant_user = tu
    @page_title = @settings_user == current_user ? "Your Settings" : "#{@settings_user.display_name}'s Settings"

    # For human users, show their AI agents
    if @settings_user.human?
      @ai_agents = @settings_user.ai_agents.includes(:tenant_users, :collective_members).where(tenant_users: { tenant_id: @current_tenant.id })
      # Collectives where settings user has invite permission (for adding AI agents)
      @invitable_studios = @settings_user.collective_members.includes(:collective).select(&:can_invite?).map(&:collective)

      # Load all API tokens: user's own + AI agents' tokens
      # Sorted by: user's tokens first, then agents alphabetically, then by created_at desc
      user_tokens = @settings_user.api_tokens.external.includes(:user).to_a
      agent_tokens = @ai_agents.flat_map { |agent| agent.api_tokens.external.includes(:user).to_a }
      @all_api_tokens = user_tokens.sort_by { |t| -t.created_at.to_i } +
        agent_tokens.sort_by { |t| [t.user.display_name.downcase, -t.created_at.to_i] }
    else
      @ai_agents = []
      @invitable_studios = []
      @all_api_tokens = @settings_user.api_tokens.external.includes(:user).order(created_at: :desc).to_a
    end

    respond_to do |format|
      format.html
      format.md
    end
  end

  def add_ai_agent_to_studio
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: 404, plain: "404 Not Found" if tu.nil?
    ai_agent = tu.user
    return render status: 403, plain: "403 Unauthorized" unless ai_agent.ai_agent? && ai_agent.parent_id == current_user.id
    collective = Collective.find(params[:collective_id])
    return render status: 403, plain: "403 Unauthorized" unless current_user.can_add_ai_agent_to_collective?(ai_agent, collective)

    # Add AI agent to the collective
    collective.add_user!(ai_agent)

    respond_to do |format|
      format.json do
        render json: {
          collective_id: collective.id,
          collective_name: collective.name,
          collective_path: collective.path,
        }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} has been added to #{collective.name}"
        redirect_to "#{current_user.path}/settings"
      end
    end
  end

  def remove_ai_agent_from_studio
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: 404, plain: "404 Not Found" if tu.nil?
    ai_agent = tu.user
    return render status: 403, plain: "403 Unauthorized" unless ai_agent.ai_agent? && ai_agent.parent_id == current_user.id

    collective = Collective.find(params[:collective_id])
    collective_member = CollectiveMember.find_by(collective: collective, user: ai_agent)
    return render status: 404, plain: "404 Not Found" if collective_member.nil? || collective_member.archived?

    collective_member.archive!

    respond_to do |format|
      format.json do
        render json: {
          collective_id: collective.id,
          collective_name: collective.name,
        }
      end
      format.html do
        flash[:notice] = "#{ai_agent.display_name} has been removed from #{collective.name}"
        redirect_to "#{current_user.path}/settings"
      end
    end
  end

  def update_profile
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404', status: 404 if tu.nil?
    settings_user = tu.user
    return render plain: '403 Unauthorized', status: 403 unless current_user.can_edit?(settings_user)

    if params[:name].present?
      settings_user.name = params[:name]
      settings_user.save!
      TenantUser.for_user_across_tenants(settings_user).update_all(
        display_name: params[:name]
      )
    end
    if params[:new_handle].present?
      tu.handle = params[:new_handle]
      tu.save!
      TenantUser.for_user_across_tenants(settings_user).where.not(id: tu.id).update_all(
        handle: params[:new_handle]
      )
    end
    # Handle identity_prompt for AI agents
    if settings_user.ai_agent? && params.key?(:identity_prompt)
      settings_user.agent_configuration ||= {}
      settings_user.agent_configuration["identity_prompt"] = params[:identity_prompt].presence
      settings_user.save!
    end
    # Handle mode for AI agents (internal vs external)
    if settings_user.ai_agent? && params.key?(:mode)
      settings_user.agent_configuration ||= {}
      mode = params[:mode]
      settings_user.agent_configuration["mode"] = %w[internal external].include?(mode) ? mode : "external"
      settings_user.save!
    end
    # Handle model for internal AI agents
    if settings_user.ai_agent? && params.key?(:model)
      settings_user.agent_configuration ||= {}
      settings_user.agent_configuration["model"] = params[:model].presence
      settings_user.save!
    end
    # Handle capabilities for AI agents
    # Checked = allowed, unchecked = blocked (standard checkbox model)
    # Empty array (all unchecked) = NO grantable actions allowed
    # nil (key absent) = all grantable actions allowed (backwards compatible default)
    if settings_user.ai_agent?
      settings_user.agent_configuration ||= {}
      capabilities = params[:capabilities]
      if capabilities.is_a?(Array) && capabilities.any?
        # Filter to only valid grantable actions
        valid_caps = capabilities & CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS
        settings_user.agent_configuration["capabilities"] = valid_caps
      else
        # All boxes unchecked = save empty array (nothing allowed)
        settings_user.agent_configuration["capabilities"] = []
      end
      settings_user.save!
    end
    flash[:notice] = 'Profile updated successfully'
    redirect_to "#{settings_user.path}/settings"
  end

  # Start representing a user (typically an AI agent).
  # POST /u/:handle/represent
  def represent
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: 404, plain: "404 Not Found" if tu.nil?

    target_user = tu.user
    return render status: 403, plain: "403 Unauthorized" unless target_user.ai_agent?
    return render status: 403, plain: "403 Unauthorized" unless current_user.can_represent?(target_user)

    # Find the TrusteeGrant for this parent-ai_agent relationship
    grant = TrusteeGrant.active.find_by(
      granting_user: target_user,
      trustee_user: current_user
    )
    return render status: 403, plain: "403 Unauthorized - No active grant" unless grant

    # Create a RepresentationSession for audit logging
    rep_session = api_helper.start_user_representation_session(grant: grant)

    # Set session cookies for representation (matches API headers)
    session[:representation_session_id] = rep_session.id
    session[:representing_user] = target_user.handle
    redirect_to "/representing"
  end

  # Stop representing a user.
  # DELETE /u/:handle/represent
  def stop_representing
    # Explicitly look up and end the representation session if present
    if session[:representation_session_id].present?
      rep_session = RepresentationSession.find_by(id: session[:representation_session_id])
      rep_session&.end!
    end
    clear_representation!
    redirect_to request.referrer || root_path
  end

  def update_image
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404', status: 404 if tu.nil?
    settings_user = tu.user
    return render plain: '403 Unauthorized', status: 403 unless current_user.can_edit?(settings_user)

    if params[:image].present?
      settings_user.image = params[:image]
    elsif params[:cropped_image_data].present?
      settings_user.cropped_image_data = params[:cropped_image_data]
    else
      return render status: 400, plain: '400 Bad Request'
    end
    settings_user.save!
    redirect_to request.referrer || "#{settings_user.path}/settings"
  end

  # Markdown API actions

  def actions_index
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404', status: 404 if tu.nil?
    @settings_user = tu.user
    return render plain: '403 Unauthorized', status: 403 unless current_user.can_edit?(@settings_user)
    @page_title = @settings_user == current_user ? "Actions | Your Settings" : "Actions | #{@settings_user.display_name}'s Settings"
    render_actions_index(ActionsHelper.actions_for_route('/u/:handle/settings'))
  end

  def describe_update_profile
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404', status: 404 if tu.nil?
    @settings_user = tu.user
    return render plain: '403 Unauthorized', status: 403 unless current_user.can_edit?(@settings_user)
    render_action_description(ActionsHelper.action_description("update_profile", resource: @settings_user))
  end

  def execute_update_profile
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404', status: 404 if tu.nil?
    @settings_user = tu.user
    return render plain: '403 Unauthorized', status: 403 unless current_user.can_edit?(@settings_user)

    if params[:name].present?
      @settings_user.name = params[:name]
      @settings_user.save!
      TenantUser.for_user_across_tenants(@settings_user).update_all(display_name: params[:name])
    end
    # Use new_handle to avoid conflict with path parameter :handle
    # Note: handle is a virtual attribute that delegates to tenant_user
    if params[:new_handle].present?
      tu.handle = params[:new_handle]
      tu.save!
      TenantUser.for_user_across_tenants(@settings_user).where.not(id: tu.id).update_all(handle: params[:new_handle])
    end

    @settings_user.tenant_user = tu
    @page_title = @settings_user == current_user ? "Your Settings" : "#{@settings_user.display_name}'s Settings"

    # For human users, show their AI agents and consolidated API tokens
    if @settings_user.human?
      @ai_agents = @settings_user.ai_agents.includes(:tenant_users, :collective_members).where(tenant_users: { tenant_id: @current_tenant.id })
      @invitable_studios = @settings_user.collective_members.includes(:collective).select(&:can_invite?).map(&:collective)

      # Load all API tokens: user's own + AI agents' tokens
      user_tokens = @settings_user.api_tokens.external.includes(:user).to_a
      agent_tokens = @ai_agents.flat_map { |agent| agent.api_tokens.external.includes(:user).to_a }
      @all_api_tokens = user_tokens.sort_by { |t| -t.created_at.to_i } +
        agent_tokens.sort_by { |t| [t.user.display_name.downcase, -t.created_at.to_i] }
    else
      @ai_agents = []
      @invitable_studios = []
      @all_api_tokens = @settings_user.api_tokens.external.includes(:user).order(created_at: :desc).to_a
    end

    respond_to do |format|
      format.md { render 'settings' }
      format.html { redirect_to "#{@settings_user.path}/settings" }
    end
  end

  private

  # Load proximity connections for the user profile being viewed
  # Returns a simple sorted list of the most proximate users
  def load_proximity_connections
    all_connections = @showing_user.most_proximate_users(tenant_id: current_tenant.id, limit: 30)

    @proximity_users = all_connections.filter_map do |user, score|
      next if user.nil? || user.archived?
      tu = user.tenant_users.find_by(tenant_id: current_tenant.id)
      next if tu.nil?
      user.tenant_user = tu
      user
    end
  end

end