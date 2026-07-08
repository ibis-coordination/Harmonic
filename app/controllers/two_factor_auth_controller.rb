# typed: false

class TwoFactorAuthController < ApplicationController
  include BotProtection

  before_action :set_auth_sidebar
  # Honeypot only — skipping Turnstile here would add a second friction surface
  # right after the user just authenticated with a password. The existing
  # rack_attack '2fa/ip' throttle (10/15min) is the brute-force backstop.
  # Run before require_pending_2fa so naive bots get logged-and-rejected
  # rather than silently redirected to /login.
  protect_from_bots only: [:verify_submit], turnstile: false
  before_action :require_pending_2fa, only: [:verify, :verify_submit]
  before_action :require_login, only: [:setup, :confirm_setup, :settings, :disable, :regenerate_codes]
  before_action :require_identity_provider, only: [:setup, :confirm_setup, :settings, :disable, :regenerate_codes]

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
      # The user just passed a TOTP challenge on this device — same proof
      # of device trust we mint a refresh token for at login. Without this,
      # a user who just enabled 2FA in their current session has zero
      # refresh tokens until they log out and back in, which means they
      # see no "Devices" on settings and lose the silent-re-auth benefit
      # until the next session expiry.
      issue_refresh_token_for!(current_user, two_factor_at: Time.current)
      @recovery_codes = identity.generate_recovery_codes!
      session.delete(:pending_otp_secret)
      SecurityAuditLog.log_2fa_enabled(identity: identity, ip: request.remote_ip)
      @continue_url = post_2fa_setup_continue_url
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
    # When the current tenant requires 2FA, hide the disable controls — the
    # activation gate would just force re-setup on the next request anyway.
    # NOTE: this is a per-current-tenant check. A user in multiple tenants
    # with different require_2fa policies could still disable from a permissive
    # tenant and then get caught by the activation gate when they hit a
    # stricter one. Acceptable for now; the gate is the source of truth.
    @can_disable = !@current_tenant.require_2fa?
  end

  # POST /settings/two-factor/disable
  def disable
    # Defense-in-depth match for the settings view: don't let a direct POST
    # bypass the hidden-from-UI guard when the tenant requires 2FA.
    if @current_tenant.require_2fa?
      flash[:alert] = "Two-factor authentication is required for this workspace and cannot be disabled."
      return redirect_to two_factor_settings_path
    end

    identity = current_identity
    code = params[:code]&.strip

    # Verify code before disabling
    is_recovery_code = code.present? && code.gsub(/\s/, "").length > 6
    valid = (is_recovery_code && identity.verify_recovery_code(code)) ||
            (!is_recovery_code && identity.verify_otp(code || ""))

    if valid
      identity.disable_otp!
      # Disabling 2FA invalidates device trust everywhere — refresh tokens
      # encode "this device passed 2FA recently" and that precondition no
      # longer holds. The user re-authenticates on each device next time.
      RefreshToken.revoke_all_for_user!(current_user.id, reason: "two_factor_disabled")
      SecurityAuditLog.log_2fa_disabled(identity: identity, ip: request.remote_ip)
      flash[:notice] = "Two-factor authentication has been disabled."
      redirect_to "/settings"
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
      redirect_to "/settings"
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

    @current_identity = current_user.omni_auth_identity
  end

  def complete_2fa_login
    identity = pending_identity

    # The OmniAuthIdentity row knows its user directly — every login path
    # (identity-provider and external OAuth alike) links it before the 2FA
    # challenge fires. The email match is a last-resort fallback for legacy
    # rows that predate the link.
    user = identity.user || User.find_by(email: identity.email)
    unless user
      flash[:alert] = "Could not complete login. Please try again."
      clear_pending_2fa_session
      redirect_to "/login"
      return
    end

    session[:user_id] = user.id
    session[:logged_in_at] = Time.current.to_i
    session[:last_activity_at] = Time.current.to_i
    issue_refresh_token_for!(user, two_factor_at: Time.current)
    clear_pending_2fa_session
    # Mirror the non-2FA branch of oauth_callback — without this, every
    # 2FA-protected login would be missing from the login-success audit
    # trail while weaker non-2FA logins are recorded.
    SecurityAuditLog.log_login_success(
      user: user,
      ip: request.remote_ip,
      user_agent: request.user_agent,
    )

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

  # Destination shown on the recovery-codes page after a fresh 2FA setup.
  # Precedence:
  #   1. session[:reverification_return_to] — the user was blocked by
  #      require_reverification on the way to some other action; honor that
  #      destination and consume the stash.
  #   2. session[:activation_return_to] present — the user came via the
  #      Phase-4 activation gate. Send them through /activate so it can
  #      consume its own stash (or auto-redirect home if all items satisfied).
  #   3. Default — /settings (the user's settings index). Less awkward than the
  #      old /settings/two-factor/manage default for users who didn't navigate
  #      here specifically to manage 2FA.
  def post_2fa_setup_continue_url
    rev_to = session.delete(:reverification_return_to)
    return rev_to if rev_to.present?
    return activation_path if session[:activation_return_to].present?
    "/settings"
  end
end
