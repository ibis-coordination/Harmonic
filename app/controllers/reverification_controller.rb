# typed: false

# Handles step-up authentication re-verification.
# Users are redirected here by the RequiresReverification concern when
# accessing a sensitive action that requires a fresh TOTP code.
class ReverificationController < ApplicationController
  before_action :require_login

  def show
    @page_title = "Verify Your Identity"
    @identity = current_user&.omni_auth_identity

    unless @identity&.otp_enabled
      flash[:alert] = "Two-factor authentication is required for this action. Please set up 2FA first."
      redirect_to two_factor_setup_path
      return
    end

    @locked = @identity.otp_locked?
    @lockout_remaining = @identity.otp_locked_until ? (@identity.otp_locked_until - Time.current).to_i : 0
    @scope = session[:reverification_scope] || "default"
  end

  def verify
    @identity = current_user&.omni_auth_identity
    code = params[:code]&.strip

    unless @identity&.otp_enabled
      redirect_to two_factor_setup_path
      return
    end

    if @identity.otp_locked?
      SecurityAuditLog.log_event(
        event: "reverification_failure",
        severity: :warn,
        user_id: current_user.id,
        ip: request.remote_ip,
        reason: "account_locked",
      )
      flash.now[:alert] = "Account is temporarily locked. Please try again later."
      @locked = true
      @lockout_remaining = (@identity.otp_locked_until - Time.current).to_i
      @scope = session[:reverification_scope] || "default"
      return render :show
    end

    if @identity.verify_otp(code || "")
      scope = session.delete(:reverification_scope) || "default"
      session[:"reverified_at_#{scope}"] = Time.current.to_i
      return_to = session.delete(:reverification_return_to) || "/"
      stashed_request = session.delete(:reverification_stashed_request)

      SecurityAuditLog.log_event(
        event: "reverification_success",
        severity: :info,
        user_id: current_user.id,
        ip: request.remote_ip,
        scope: scope,
      )

      if stashed_request && stashed_request["path"]&.start_with?("/")
        # Store for the GET replay page (the CSRF token must be generated
        # on a GET response to avoid per-form token mismatches)
        session[:reverification_replay] = stashed_request
        redirect_to reverify_replay_path
      else
        redirect_to return_to
      end
    else
      SecurityAuditLog.log_event(
        event: "reverification_failure",
        severity: :warn,
        user_id: current_user.id,
        ip: request.remote_ip,
        reason: "invalid_code",
      )

      if @identity.otp_locked?
        flash.now[:alert] = "Too many failed attempts. Account is temporarily locked."
        @locked = true
        @lockout_remaining = (@identity.otp_locked_until - Time.current).to_i
      else
        flash.now[:alert] = "Invalid verification code. Please try again."
      end
      @scope = session[:reverification_scope] || "default"
      render :show
    end
  end

  # GET /reverify/replay — renders auto-submit form for stashed request
  def replay
    stashed_request = session.delete(:reverification_replay)
    unless stashed_request && stashed_request["path"]&.start_with?("/")
      return redirect_to "/"
    end

    @stashed_method = stashed_request["method"]
    @stashed_path = stashed_request["path"]
    @stashed_params = stashed_request["params"] || {}
  end

  private

  def is_auth_controller?
    true
  end

  def require_login
    return if current_user

    redirect_to "/login"
  end
end
