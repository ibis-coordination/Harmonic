# typed: false

# Activation checklist page — the destination for the activation gate (see
# ApplicationController#check_activation_gate). Shows three items, each
# satisfied by following an existing flow (invite acceptance, email
# confirmation, 2FA setup).
class ActivationController < ApplicationController
  def show
    return redirect_to "/login" unless @current_user
    # Operators are exempt — send them home.
    return redirect_to root_path if @current_user.sys_admin? || @current_user.app_admin?
    # The activation flow is human-facing only; non-human session users (via
    # representation, etc.) shouldn't see the checklist.
    return redirect_to root_path unless @current_user.human?

    @sidebar_mode = "none"
    @hide_header = true
    @page_title = "Activate your account"
    @items = activation_items
    @all_satisfied = @items.all? { |i| i[:satisfied] }
    # When everything's done already, bounce them out so /activate isn't
    # accidentally a parking page. (The gate redirects here only when at least
    # one item is incomplete; direct visits after completion should pass through.)
    if @all_satisfied
      return_to = session.delete(:activation_return_to)
      return redirect_to(safe_return_path?(return_to) ? return_to : root_path)
    end

    render layout: "application"
  end

  def send_email_confirmation
    return redirect_to "/login" unless @current_user

    identity = @current_user.find_or_create_omni_auth_identity!
    if identity.email_verified?
      flash[:notice] = "Your email is already verified."
    else
      raw_token = identity.send_email_confirmation!
      EmailConfirmationMailer.confirm(identity, raw_token, @current_tenant).deliver_later
      flash[:notice] = "Confirmation email sent to #{identity.email}."
    end
    redirect_to activation_path
  end

  private

  # The activation gate (and this page) treat each item as required; tenant
  # flags can hide an item entirely so it's not part of the checklist.
  def activation_items
    items = [invite_item]
    items << email_item if @current_tenant.require_verified_email?
    items << two_factor_item if @current_tenant.require_2fa?
    items
  end

  def invite_item
    # NOTE: The existing `current_invite` helper looks at `cookies[:invite_code]`
    # but the cookie actually set during signup is `:collective_invite_code`
    # (set in SessionsController#redirect_to_auth_domain). A future commit can
    # bridge the two so a pending invite cookie satisfies #1 without forcing
    # acceptance first; for now we use tenant membership as the sole signal.
    satisfied = @current_tenant.tenant_users.exists?(user: @current_user)
    body = satisfied ? "You're a member of #{@current_tenant.name}." : "Enter an invite code to continue."
    {
      key: :invite,
      title: "Join #{@current_tenant.name}",
      body: body,
      satisfied: satisfied,
      action_path: invite_required_path,
      action_label: satisfied ? "Manage invite" : "Enter invite code",
    }
  end

  def email_item
    satisfied = @current_user.email_verified?
    {
      key: :email,
      title: "Verify your email",
      body: satisfied ? "Confirmed." : "We'll send a confirmation link to #{@current_user.email}.",
      satisfied: satisfied,
      action_path: resend_email_confirmation_path,
      action_method: :post,
      action_label: satisfied ? nil : "Send confirmation email",
    }
  end

  def two_factor_item
    satisfied = @current_user.two_factor_enabled?
    {
      key: :two_factor,
      title: "Enable two-factor authentication",
      body: satisfied ? "Enabled." : "Use an authenticator app (Google Authenticator, 1Password, etc.).",
      satisfied: satisfied,
      action_path: two_factor_setup_path,
      action_label: satisfied ? "Manage" : "Set up 2FA",
    }
  end

  # Mirror BillingController#safe_return_path? — relative paths only, no
  # protocol-relative, no control chars.
  def safe_return_path?(path)
    return false if path.blank?
    return false unless path.start_with?("/")
    return false if path.start_with?("//")
    return false if path.match?(/[\r\n\t\0]/)
    return false if path.match?(/[^a-zA-Z0-9\-._~:\/?#\[\]@!$&'()*+,;=%]/)

    true
  end

  # Treated as auth-flow so the activation gate doesn't recurse on itself, and
  # so the page is reachable without billing or collective context.
  def is_auth_controller?
    true
  end
end
