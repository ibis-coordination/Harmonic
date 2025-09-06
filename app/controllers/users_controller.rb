class UsersController < ApplicationController
  def index
    @users = current_tenant.tenant_users
  end

  def show
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404' if tu.nil?
    @showing_user = tu.user
    @showing_user.tenant_user = tu
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
  end

  def settings
    tu = current_tenant.tenant_users.find_by(handle: params[:handle])
    return render '404' if tu.nil?
    return render plain: '403 Unauthorized' unless tu.user == current_user
    @current_user.tenant_user = tu
    @simulated_users = @current_user.simulated_users.includes(:tenant_users).where(tenant_users: {tenant_id: @current_tenant.id})
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
    return render status: 404, plain: '404 Not Found' if tu.nil?
    return render status: 403, plain: '403 Unauthorized' unless current_user.can_impersonate?(tu.user)
    return render status: 403, plain: '403 Unauthorized' unless tu.user.simulated?
    session[:simulated_user_id] = tu.user.id
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

end