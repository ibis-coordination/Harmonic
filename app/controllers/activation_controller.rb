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
      if safe_return_path?(return_to)
        return redirect_to(return_to)
      end
      flash[:notice] = "Your account is now active!"
      return redirect_to root_path
    end

    render layout: "application"
  end

  def send_email_confirmation
    return redirect_to "/login" unless @current_user

    identity = @current_user.find_or_create_omni_auth_identity!
    if identity.email_verified?
      flash[:notice] = "Your email is already verified."
    elsif !identity.can_send_email_confirmation?
      wait = identity.email_confirmation_resend_wait
      flash[:alert] = "Please wait #{wait} #{'second'.pluralize(wait)} before requesting another confirmation email."
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
    # Check #1 in the activation flow: tenant membership OR a valid pending
    # invite cookie. The latter lets a user clear this item just by holding
    # a fresh invite — they don't have to actually accept yet (acceptance is
    # a follow-up action after the whole checklist is done).
    is_member = @current_tenant.tenant_users.exists?(user: @current_user)
    pending_invite = pending_invite_for_current_tenant
    satisfied = is_member || pending_invite.present?
    body = if is_member
             "You have accepted your invite."
           elsif pending_invite
             "Invite found — accept it once your account is fully active."
           else
             "Enter an invite code to continue."
           end
    {
      key: :invite,
      title: "Accept invite",
      body: body,
      satisfied: satisfied,
      action_path: invite_required_path,
      # No action button when satisfied — there's no separate invite-management
      # UI to send the user to, and /invite-required would just bounce them
      # back here via root_path.
      action_label: satisfied ? nil : "Enter invite code",
    }
  end

  # Tenant-wide invite-cookie lookup. The application_controller's
  # `current_invite` helper is collective-scoped (and `/activate` lives on
  # the bare tenant subdomain, where current_collective is the main
  # collective), so it can't see invites for non-main collectives. This
  # finds any invite in the current tenant matching the cookie code that
  # the user is still able to accept.
  def pending_invite_for_current_tenant
    code = cookies[:collective_invite_code]
    return nil if code.blank?
    invite = Invite.tenant_scoped_only(@current_tenant.id).find_by(code: code)
    return nil unless invite&.is_acceptable_by_user?(@current_user)
    invite
  end

  def email_item
    satisfied = @current_user.email_verified?
    identity = @current_user.omni_auth_identity
    already_sent = identity&.email_confirmation_sent_at.present?
    body = if satisfied
             "Confirmed."
           elsif already_sent
             "We sent a confirmation link to #{@current_user.email}. Click the link to verify, or resend if it didn't arrive."
           else
             "We'll send a confirmation link to #{@current_user.email}."
           end
    label = if satisfied
              nil
            elsif already_sent
              "Resend confirmation email"
            else
              "Send confirmation email"
            end
    {
      key: :email,
      title: "Verify your email",
      body: body,
      satisfied: satisfied,
      action_path: resend_email_confirmation_path,
      action_method: :post,
      action_label: label,
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
