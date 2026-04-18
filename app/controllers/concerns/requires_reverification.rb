# typed: false

# RequiresReverification provides step-up authentication for sensitive actions.
#
# When included in a controller, call `require_reverification(scope:)` as a
# before_action to gate actions behind a fresh TOTP code entry. The user's
# identity is re-verified via their OmniAuthIdentity's OTP, independent of
# whether they originally logged in via OAuth or email/password.
#
# Usage:
#   include RequiresReverification
#   before_action -> { require_reverification(scope: "admin") }
#
# Or selectively:
#   before_action -> { require_reverification(scope: "destructive") }, only: [:destroy]
#
# Scopes are independent — verifying for "admin" does not satisfy "destructive".
# The timeout is shared across all scopes, configurable via REVERIFICATION_TIMEOUT
# (default 1 hour).
module RequiresReverification
  extend ActiveSupport::Concern

  private

  def require_reverification(scope: "default")
    return if api_token_present?
    return unless @current_user

    identity = @current_user.omni_auth_identity
    unless identity&.otp_enabled
      flash[:alert] = "Two-factor authentication is required for this action. Please set up 2FA first."
      redirect_to two_factor_setup_path
      return
    end

    session_key = :"reverified_at_#{scope}"
    timeout = ENV.fetch("REVERIFICATION_TIMEOUT", "3600").to_i
    verified_at = session[session_key]

    if verified_at.present? && Time.at(verified_at) > timeout.seconds.ago
      return # recently verified
    end

    session[:reverification_return_to] = request.original_url
    session[:reverification_scope] = scope
    redirect_to reverify_path
  end
end
