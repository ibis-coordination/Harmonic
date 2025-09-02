class PasswordResetsController < ApplicationController
  before_action :find_identity_by_token, only: [:show, :update]

  def new
    # Form to request password reset
  end

  def create
    @identity = OmniAuthIdentity.find_by(email: params[:email].downcase.strip)

    if @identity
      @identity.generate_reset_password_token!
      PasswordResetMailer.reset_password_instructions(@identity).deliver_now
    end
    flash[:notice] = "If an account with that email exists, password reset instructions have been sent."

    redirect_to new_password_reset_path
  end

  def show
    # Form to reset password with token
    if @identity.nil? || !@identity.reset_password_token_valid?
      flash[:alert] = "Password reset link has expired or is invalid. Please request a new one."
      redirect_to new_password_reset_path
    end
  end

  def update
    if @identity.nil? || !@identity.reset_password_token_valid?
      flash[:alert] = "Password reset link has expired or is invalid. Please request a new one."
      redirect_to new_password_reset_path
      return
    end

    if params[:password].present? && params[:password] == params[:password_confirmation]
      if params[:password].length >= 14
        @identity.update_password!(params[:password])
        flash[:notice] = "Your password has been updated successfully. You can now log in."
        redirect_to '/login'
      else
        flash.now[:alert] = "Password must be at least 14 characters long."
        render :show
      end
    else
      flash.now[:alert] = "Password and confirmation must match and cannot be blank."
      render :show
    end
  end

  private

  def find_identity_by_token
    @identity = OmniAuthIdentity.find_by_reset_password_token(params[:token]) if params[:token].present?
  end

  def is_auth_controller?
    true
  end

  def current_resource_model
    OmniAuthIdentity
  end
end
