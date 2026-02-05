# typed: false

class TwoFactorAuthController < ApplicationController
  before_action :set_auth_sidebar
  before_action :require_pending_2fa, only: [:verify, :verify_submit]
  before_action :require_login, only: [:setup, :confirm_setup, :settings, :disable, :regenerate_codes]
  before_action :require_identity_provider, only: [:setup, :confirm_setup, :settings, :disable, :regenerate_codes]
  skip_forgery_protection only: [:verify_submit]

  # === Login Verification ===

  # GET /login/verify-2fa
  def verify
    @page_title = "Two-Factor Authentication | Harmonic"
    @identity = pending_identity
    @locked = @identity.otp_locked?
    @lockout_remaining = @identity.otp_locked_until ? (@identity.otp_locked_until - Time.current).to_i : 0
  end

  # POST /login/verify-2fa
  def verify_submit
    @identity = pending_identity
    code = params[:code]&.strip

    if @identity.otp_locked?
      SecurityAuditLog.log_2fa_lockout(identity: @identity, ip: request.remote_ip)
      flash.now[:alert] = "Account is temporarily locked. Please try again later."
      @locked = true
      @lockout_remaining = (@identity.otp_locked_until - Time.current).to_i
      return render :verify
    end

    # Check if code looks like a recovery code (16 hex chars) vs TOTP (6 digits)
    is_recovery_code = code.present? && code.gsub(/\s/, "").length > 6

    if is_recovery_code && @identity.verify_recovery_code(code)
      SecurityAuditLog.log_2fa_recovery_code_used(
        identity: @identity,
        ip: request.remote_ip,
        remaining_codes: @identity.remaining_recovery_codes_count,
      )
      complete_2fa_login
    elsif !is_recovery_code && @identity.verify_otp(code || "")
      SecurityAuditLog.log_2fa_success(identity: @identity, ip: request.remote_ip)
      complete_2fa_login
    else
      SecurityAuditLog.log_2fa_failure(identity: @identity, ip: request.remote_ip)

      if @identity.otp_locked?
        SecurityAuditLog.log_2fa_lockout(identity: @identity, ip: request.remote_ip)
        flash.now[:alert] = "Too many failed attempts. Account is temporarily locked."
        @locked = true
        @lockout_remaining = (@identity.otp_locked_until - Time.current).to_i
      else
        flash.now[:alert] = "Invalid verification code. Please try again."
      end
      render :verify
    end
  end

  # === Setup Flow ===

  # GET /settings/two-factor
  def setup
    @page_title = "Set Up Two-Factor Authentication | Harmonic"
    identity = current_identity

    if identity.otp_enabled
      redirect_to two_factor_settings_path
      return
    end

    # Generate or retrieve pending secret
    if session[:pending_otp_secret].blank?
      identity.generate_otp_secret!
      session[:pending_otp_secret] = identity.otp_secret
    else
      identity.update!(otp_secret: session[:pending_otp_secret])
    end

    @provisioning_uri = identity.otp_provisioning_uri
    @qr_code = generate_qr_code(@provisioning_uri)
    @secret = identity.otp_secret
  end

  # POST /settings/two-factor/confirm
  def confirm_setup
    identity = current_identity
    code = params[:code]&.strip

    if identity.verify_otp(code || "")
      identity.enable_otp!
      @recovery_codes = identity.generate_recovery_codes!
      session.delete(:pending_otp_secret)
      SecurityAuditLog.log_2fa_enabled(identity: identity, ip: request.remote_ip)
      render :show_recovery_codes
    else
      flash[:alert] = "Invalid verification code. Please try again."
      redirect_to two_factor_setup_path
    end
  end

  # === Management ===

  # GET /settings/two-factor/manage
  def settings
    @page_title = "Two-Factor Authentication Settings | Harmonic"
    identity = current_identity

    unless identity.otp_enabled
      redirect_to two_factor_setup_path
      return
    end

    @remaining_codes = identity.remaining_recovery_codes_count
    @enabled_at = identity.otp_enabled_at
  end

  # POST /settings/two-factor/disable
  def disable
    identity = current_identity
    code = params[:code]&.strip

    # Verify code before disabling
    is_recovery_code = code.present? && code.gsub(/\s/, "").length > 6
    valid = (is_recovery_code && identity.verify_recovery_code(code)) ||
            (!is_recovery_code && identity.verify_otp(code || ""))

    if valid
      identity.disable_otp!
      SecurityAuditLog.log_2fa_disabled(identity: identity, ip: request.remote_ip)
      flash[:notice] = "Two-factor authentication has been disabled."
      redirect_to "/u/#{current_user.handle}/settings"
    else
      flash[:alert] = "Invalid verification code. 2FA was not disabled."
      redirect_to two_factor_settings_path
    end
  end

  # POST /settings/two-factor/regenerate-codes
  def regenerate_codes
    identity = current_identity
    code = params[:code]&.strip

    # Verify code before regenerating
    if identity.verify_otp(code || "")
      @recovery_codes = identity.generate_recovery_codes!
      SecurityAuditLog.log_2fa_recovery_codes_regenerated(identity: identity, ip: request.remote_ip)
      render :show_recovery_codes
    else
      flash[:alert] = "Invalid verification code. Recovery codes were not regenerated."
      redirect_to two_factor_settings_path
    end
  end

  private

  def set_auth_sidebar
    @sidebar_mode = "none"
    @hide_header = true
  end

  def is_auth_controller?
    true
  end

  def require_pending_2fa
    unless pending_identity
      redirect_to "/login"
    end
  end

  def require_login
    return if current_user

    respond_to do |format|
      format.html { redirect_to "/login" }
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
    end
  end

  def require_identity_provider
    unless current_identity
      flash[:alert] = "Two-factor authentication is only available for email/password accounts."
      redirect_to "/u/#{current_user.handle}/settings"
    end
  end

  def pending_identity
    return @pending_identity if defined?(@pending_identity)

    identity_id = session[:pending_2fa_identity_id]
    started_at = session[:pending_2fa_started_at]

    # Check for timeout (5 minutes)
    if identity_id && started_at && started_at < 5.minutes.ago.to_i
      clear_pending_2fa_session
      return @pending_identity = nil
    end

    @pending_identity = identity_id ? OmniAuthIdentity.find_by(id: identity_id) : nil
  end

  def current_identity
    return @current_identity if defined?(@current_identity)
    return @current_identity = nil unless current_user

    # Find OmniAuthIdentity associated with current user's email
    @current_identity = OmniAuthIdentity.find_by(email: current_user.email)
  end

  def complete_2fa_login
    identity = pending_identity

    # Find the user associated with this identity via OauthIdentity (provider: identity)
    oauth_identity = OauthIdentity.find_by(provider: "identity", uid: identity.id.to_s)
    unless oauth_identity
      # Fallback: find user by email directly
      user = User.find_by(email: identity.email)
      unless user
        flash[:alert] = "Could not complete login. Please try again."
        clear_pending_2fa_session
        redirect_to "/login"
        return
      end
      session[:user_id] = user.id
    else
      session[:user_id] = oauth_identity.user.id
    end

    session[:logged_in_at] = Time.current.to_i
    session[:last_activity_at] = Time.current.to_i
    clear_pending_2fa_session

    redirect_to "/login/return"
  end

  def clear_pending_2fa_session
    session.delete(:pending_2fa_identity_id)
    session.delete(:pending_2fa_started_at)
  end

  def generate_qr_code(uri)
    qrcode = RQRCode::QRCode.new(uri)
    qrcode.as_svg(
      color: "000",
      shape_rendering: "crispEdges",
      module_size: 4,
      standalone: true,
      use_path: true,
    )
  end
end
