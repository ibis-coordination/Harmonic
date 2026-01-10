# typed: false

class UsersController < ApplicationController
  def index
    @users = current_tenant.tenant_users
  end

  def show
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404' if tu.nil?
    @showing_user = tu.user
    @showing_user.tenant_user = tu
    @page_title = @showing_user.display_name
    if params[:studio_handle]
      # Showing user in a specific studio
      su = @showing_user.studio_users.where(studio: current_studio).first
      return render '404' if su.nil?
      @showing_user.studio_user = su
      @common_studios = [current_studio]
      @additional_common_studio_count = (
        current_user.studios & @showing_user.studios - [current_tenant.main_studio]
      ).count - 1
    else
      # Showing user at the tenant level, so we want to show all common studios between the current user and the showing user
      @common_studios = current_user.studios & @showing_user.studios - [current_tenant.main_studio]
      @additional_common_studio_count = 0
    end
    respond_to do |format|
      format.html
      format.md
    end
  end

  def settings
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404' if tu.nil?
    return render plain: '403 Unauthorized' unless tu.user == current_user
    @page_title = "Your Settings"
    @current_user.tenant_user = tu
    @subagents = @current_user.subagents.includes(:tenant_users, :studio_users).where(tenant_users: { tenant_id: @current_tenant.id })
    # Studios where current user has invite permission (for adding subagents)
    @invitable_studios = @current_user.studio_users.includes(:studio).select(&:can_invite?).map(&:studio)
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
    studio = Studio.find(params[:studio_id])
    return render status: 403, plain: "403 Unauthorized" unless current_user.can_add_subagent_to_studio?(subagent, studio)

    # Add subagent to the studio
    studio.add_user!(subagent)

    respond_to do |format|
      format.json do
        render json: {
          studio_id: studio.id,
          studio_name: studio.name,
          studio_path: studio.path,
        }
      end
      format.html do
        flash[:notice] = "#{subagent.display_name} has been added to #{studio.name}"
        redirect_to "#{current_user.path}/settings"
      end
    end
  end

  def remove_subagent_from_studio
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render status: 404, plain: "404 Not Found" if tu.nil?
    subagent = tu.user
    return render status: 403, plain: "403 Unauthorized" unless subagent.subagent? && subagent.parent_id == current_user.id

    studio = Studio.find(params[:studio_id])
    studio_user = StudioUser.find_by(studio: studio, user: subagent)
    return render status: 404, plain: "404 Not Found" if studio_user.nil? || studio_user.archived?

    studio_user.archive!

    respond_to do |format|
      format.json do
        render json: {
          studio_id: studio.id,
          studio_name: studio.name,
        }
      end
      format.html do
        flash[:notice] = "#{subagent.display_name} has been removed from #{studio.name}"
        redirect_to "#{current_user.path}/settings"
      end
    end
  end

  def update_profile
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404' if tu.nil?
    return render plain: '403 Unauthorized' unless tu.user == current_user
    if params[:name].present?
      current_user.name = params[:name]
      current_user.save!
      TenantUser.unscoped.where(user: current_user).update_all(
        display_name: params[:name]
      )
    end
    if params[:new_handle].present?
      current_user.handle = params[:new_handle]
      current_user.save!
      TenantUser.unscoped.where(user: current_user).update_all(
        handle: params[:new_handle]
      )
    end
    flash[:notice] = 'Profile updated successfully'
    redirect_to "#{current_user.path}/settings"
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
    return render '404' if tu.nil?
    return render plain: '403 Unauthorized' unless tu.user == current_user
    if params[:image].present?
      current_user.image = params[:image]
    elsif params[:cropped_image_data].present?
      current_user.cropped_image_data = params[:cropped_image_data]
    else
      return render status: 400, plain: '400 Bad Request'
    end
    current_user.save!
    redirect_to request.referrer
  end

  # Markdown API actions

  def actions_index
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404', status: 404 if tu.nil?
    return render plain: '403 Unauthorized', status: 403 unless tu.user == current_user
    @page_title = "Actions | Your Settings"
    render_actions_index(ActionsHelper.actions_for_route('/u/:handle/settings'))
  end

  def describe_update_profile
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404', status: 404 if tu.nil?
    return render plain: '403 Unauthorized', status: 403 unless tu.user == current_user
    render_action_description({
      action_name: 'update_profile',
      resource: current_user,
      description: 'Update your profile name and/or handle',
      params: [
        { name: 'name', type: 'string', description: 'Your display name' },
        { name: 'new_handle', type: 'string', description: 'Your unique handle (used in URLs)' },
      ],
    })
  end

  def execute_update_profile
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404', status: 404 if tu.nil?
    return render plain: '403 Unauthorized', status: 403 unless tu.user == current_user

    if params[:name].present?
      current_user.name = params[:name]
      current_user.save!
      TenantUser.unscoped.where(user: current_user).update_all(display_name: params[:name])
    end
    # Use new_handle to avoid conflict with path parameter :handle
    # Note: handle is a virtual attribute that delegates to tenant_user
    if params[:new_handle].present?
      current_user.handle = params[:new_handle]
      current_user.tenant_user.save!
      # Also update all other tenant_users for this user
      TenantUser.unscoped.where(user: current_user).where.not(id: current_user.tenant_user.id).update_all(handle: params[:new_handle])
    end

    @page_title = "Your Settings"
    @current_user.tenant_user = tu
    @subagents = @current_user.subagents.includes(:tenant_users, :studio_users).where(tenant_users: { tenant_id: @current_tenant.id })
    @invitable_studios = @current_user.studio_users.includes(:studio).select(&:can_invite?).map(&:studio)
    respond_to do |format|
      format.md { render 'settings' }
      format.html { redirect_to "#{current_user.path}/settings" }
    end
  end

end