# typed: false

# Handles the GET request from the confirmation email's link. Reachable
# without an authenticated session (the email link IS the proof of ownership),
# and exempt from billing / activation gates for the same reason.
class EmailConfirmationsController < ApplicationController
  def confirm
    identity = OmniAuthIdentity.find_by_email_confirmation_token(params[:token])
    return render plain: "404 not found", status: :not_found if identity.nil?

    @already_verified = identity.email_verified?
    @confirmed = identity.confirm_email!(params[:token])
    @email = identity.email

    # Clear any stale activation-return-to. The user arrived here via an email
    # link, not via a gate redirect — they shouldn't be bounced to whatever the
    # last gate-firing page was when they next visit /activate.
    session.delete(:activation_return_to)

    @sidebar_mode = "none"
    @hide_header = true
    @page_title = @confirmed ? "Email confirmed" : "Confirmation link expired"
    status = @confirmed ? :ok : :unprocessable_entity
    render layout: "application", status: status
  end

  # Treat as auth-flow so the various gates don't recurse / redirect on this
  # endpoint. Visitors to the link are usually not logged in.
  def is_auth_controller?
    true
  end

  # Login isn't required — the URL token authorizes the action.
  def token_authenticated_action?
    true
  end
end
