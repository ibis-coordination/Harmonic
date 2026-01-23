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
    # Load subagent count for person users
    if @showing_user.person?
      @subagent_count = @showing_user.subagents
        .joins(:tenant_users)
        .where(tenant_users: { tenant_id: current_tenant.id })
        .count
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
    @subagents = @current_user.subagents.includes(:tenant_users, :superagent_members).where(tenant_users: { tenant_id: @current_tenant.id })
    # Superagents where current user has invite permission (for adding subagents)
    @invitable_studios = @current_user.superagent_members.includes(:superagent).select(&:can_invite?).map(&:superagent)
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

  def update_ui_version
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404' if tu.nil?
    return render plain: '403 Unauthorized', status: 403 unless tu.user == current_user

    version = params[:ui_version]
    unless TenantUser::UI_VERSIONS.include?(version)
      flash[:alert] = 'Invalid UI version'
      redirect_to "#{current_user.path}/settings"
      return
    end

    current_user.set_ui_version!(version)
    flash[:notice] = "UI version set to #{version}"
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
    render_action_description(ActionsHelper.action_description("update_profile", resource: current_user))
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
    @subagents = @current_user.subagents.includes(:tenant_users, :superagent_members).where(tenant_users: { tenant_id: @current_tenant.id })
    @invitable_studios = @current_user.superagent_members.includes(:superagent).select(&:can_invite?).map(&:superagent)
    respond_to do |format|
      format.md { render 'settings' }
      format.html { redirect_to "#{current_user.path}/settings" }
    end
  end

end