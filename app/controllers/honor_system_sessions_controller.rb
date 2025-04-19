class HonorSystemSessionsController < ApplicationController
  before_action :check_honor_system_auth_enabled

  def new
    if current_user
      redirect_to root_path
    else
      @page_title = 'Login | Harmonic Team'
    end
  end

  def create
    if current_user
      redirect_to root_path
    elsif params[:email].blank?
      flash.now[:alert] = 'Please enter your email address.'
      @page_title = 'Login | Harmonic Team'
      return render 'sessions/new'
    else
      @current_user = User.find_by(email: params[:email]) || User.create!(
        email: params[:email],
        name: params[:name].presence || params[:email],
        user_type: 'person'
      )
      @current_user.update!(name: params[:name]) if params[:name].present?
      tenant_user = current_tenant.tenant_users.where(user: @current_user).first
      if tenant_user.nil?
        tenant_user = current_tenant.add_user!(@current_user)
      end
      tenant_user.update!(display_name: @current_user.name) if params[:name].present?
      session[:user_id] = @current_user.id
      redirect_to root_path
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to '/logout-success'
  end

  def logout_success
    if current_user
      redirect_to root_path
    else
      @page_title = 'Logout Success | Harmonic Team'
      render 'sessions/logout_success'
    end
  end

  private

  def check_honor_system_auth_enabled
    if ENV['AUTH_MODE'] != 'honor_system'
      raise 'Honor System auth is not enabled'
    end
  end
end