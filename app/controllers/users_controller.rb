# typed: false

class UsersController < ApplicationController
  layout 'pulse', only: [:index, :show, :settings]

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
    if params[:superagent_handle]
      # Showing user in a specific superagent
      sm = @showing_user.superagent_members.where(superagent: current_superagent).first
      return render '404' if sm.nil?
      @showing_user.superagent_member = sm
      @common_studios = [current_superagent]
      @additional_common_studio_count = (
        current_user.superagents & @showing_user.superagents - [current_tenant.main_superagent]
      ).count - 1
    else
      # Showing user at the tenant level, so we want to show all common superagents between the current user and the showing user
      @common_studios = current_user.superagents & @showing_user.superagents - [current_tenant.main_superagent]
      @additional_common_studio_count = 0
    end

    # Compute counts of common studios and scenes for profile display
    if @current_user != @showing_user
      all_common = current_user.superagents & @showing_user.superagents - [current_tenant.main_superagent]
      @common_studio_count = all_common.count { |s| s.superagent_type == "studio" }
      @common_scene_count = all_common.count { |s| s.superagent_type == "scene" }
    else
      @common_studio_count = 0
      @common_scene_count = 0
    end
    # Load subagent count for person users
    if @showing_user.person?
      @subagent_count = @showing_user.subagents
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

    # For person users, show their subagents
    if @settings_user.person?
      @subagents = @settings_user.subagents.includes(:tenant_users, :superagent_members).where(tenant_users: { tenant_id: @current_tenant.id })
      # Superagents where settings user has invite permission (for adding subagents)
      @invitable_studios = @settings_user.superagent_members.includes(:superagent).select(&:can_invite?).map(&:superagent)
    else
      @subagents = []
      @invitable_studios = []
    end

    respond_to do |format|
      format.html
      format.md
    end
  end

  def add_subagent_to_studio
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: 404, plain: "404 Not Found" if tu.nil?
    subagent = tu.user
    return render status: 403, plain: "403 Unauthorized" unless subagent.subagent? && subagent.parent_id == current_user.id
    superagent = Superagent.find(params[:superagent_id])
    return render status: 403, plain: "403 Unauthorized" unless current_user.can_add_subagent_to_superagent?(subagent, superagent)

    # Add subagent to the superagent
    superagent.add_user!(subagent)

    respond_to do |format|
      format.json do
        render json: {
          superagent_id: superagent.id,
          superagent_name: superagent.name,
          superagent_path: superagent.path,
        }
      end
      format.html do
        flash[:notice] = "#{subagent.display_name} has been added to #{superagent.name}"
        redirect_to "#{current_user.path}/settings"
      end
    end
  end

  def remove_subagent_from_studio
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: 404, plain: "404 Not Found" if tu.nil?
    subagent = tu.user
    return render status: 403, plain: "403 Unauthorized" unless subagent.subagent? && subagent.parent_id == current_user.id

    superagent = Superagent.find(params[:superagent_id])
    superagent_member = SuperagentMember.find_by(superagent: superagent, user: subagent)
    return render status: 404, plain: "404 Not Found" if superagent_member.nil? || superagent_member.archived?

    superagent_member.archive!

    respond_to do |format|
      format.json do
        render json: {
          superagent_id: superagent.id,
          superagent_name: superagent.name,
        }
      end
      format.html do
        flash[:notice] = "#{subagent.display_name} has been removed from #{superagent.name}"
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
      TenantUser.unscoped.where(user: settings_user).update_all(
        display_name: params[:name]
      )
    end
    if params[:new_handle].present?
      tu.handle = params[:new_handle]
      tu.save!
      # Also update all other tenant_users for this user
      TenantUser.unscoped.where(user: settings_user).where.not(id: tu.id).update_all(
        handle: params[:new_handle]
      )
    end
    # Handle identity_prompt for subagents
    if settings_user.subagent? && params.key?(:identity_prompt)
      settings_user.agent_configuration ||= {}
      settings_user.agent_configuration["identity_prompt"] = params[:identity_prompt].presence
      settings_user.save!
    end
    # Handle mode for subagents (internal vs external)
    if settings_user.subagent? && params.key?(:mode)
      settings_user.agent_configuration ||= {}
      mode = params[:mode]
      settings_user.agent_configuration["mode"] = %w[internal external].include?(mode) ? mode : "external"
      settings_user.save!
    end
    # Handle capabilities for subagents
    # Checked = allowed, unchecked = blocked (standard checkbox model)
    # Empty array (all unchecked) = NO grantable actions allowed
    # nil (key absent) = all grantable actions allowed (backwards compatible default)
    if settings_user.subagent?
      settings_user.agent_configuration ||= {}
      capabilities = params[:capabilities]
      if capabilities.is_a?(Array) && capabilities.any?
        # Filter to only valid grantable actions
        valid_caps = capabilities & CapabilityCheck::SUBAGENT_GRANTABLE_ACTIONS
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

  def impersonate
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: 404, plain: "404 Not Found" if tu.nil?
    return render status: 403, plain: "403 Unauthorized" unless current_user.can_impersonate?(tu.user)
    return render status: 403, plain: "403 Unauthorized" unless tu.user.subagent?
    session[:subagent_user_id] = tu.user.id
    redirect_to root_path
  end

  def stop_impersonating
    clear_impersonations_and_representations!
    redirect_to request.referrer
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
      TenantUser.unscoped.where(user: @settings_user).update_all(display_name: params[:name])
    end
    # Use new_handle to avoid conflict with path parameter :handle
    # Note: handle is a virtual attribute that delegates to tenant_user
    if params[:new_handle].present?
      tu.handle = params[:new_handle]
      tu.save!
      # Also update all other tenant_users for this user
      TenantUser.unscoped.where(user: @settings_user).where.not(id: tu.id).update_all(handle: params[:new_handle])
    end

    @settings_user.tenant_user = tu
    @page_title = @settings_user == current_user ? "Your Settings" : "#{@settings_user.display_name}'s Settings"

    # For person users, show their subagents
    if @settings_user.person?
      @subagents = @settings_user.subagents.includes(:tenant_users, :superagent_members).where(tenant_users: { tenant_id: @current_tenant.id })
      @invitable_studios = @settings_user.superagent_members.includes(:superagent).select(&:can_invite?).map(&:superagent)
    else
      @subagents = []
      @invitable_studios = []
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