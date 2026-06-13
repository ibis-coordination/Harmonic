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
      # A pending invite outranks the stashed return path: a non-member with
      # a finished checklist still has to explicitly accept their invite, so
      # send them to the confirmation page rather than dropping them at root
      # (where the membership gate would bounce them anyway).
      if !tenant_member? && pending_invite
        return redirect_to invite_required_path(code: pending_invite.code)
      end
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
    # Check #1 in the activation flow: tenant membership OR a pending invite
    # stashed in the session by the login callback. The latter lets a user
    # clear this item just by holding a fresh invite — acceptance stays an
    # explicit step on the /invite-required confirmation page.
    body, action_path, action_label =
      if tenant_member?
        # No action button — there's no separate invite-management UI.
        ["You have accepted your invite.", nil, nil]
      elsif pending_invite
        ["Invite to #{pending_invite.collective.name} found — review and accept it on the confirmation page.",
         invite_required_path(code: pending_invite.code), "Review invite",]
      else
        ["Enter an invite code to continue.", invite_required_path, "Enter invite code"]
      end
    {
      key: :invite,
      title: "Accept invite",
      body: body,
      satisfied: tenant_member? || pending_invite.present?,
      action_path: action_path,
      action_label: action_label,
    }
  end

  def tenant_member?
    return @tenant_member if defined?(@tenant_member)

    @tenant_member = @current_tenant.tenant_users.exists?(user: @current_user)
  end

  # Pending invite from the per-tenant session stash (see PendingInviteStash).
  # The application_controller's `current_invite` helper is collective-scoped
  # (and `/activate` lives on the bare tenant subdomain, where
  # current_collective is the main collective), so it can't see invites for
  # non-main collectives. Memoized — both the checklist item and the
  # all-satisfied redirect read it on the same request. Members skip the
  # lookup entirely; their pending stash is moot.
  def pending_invite
    return @pending_invite if defined?(@pending_invite)

    @pending_invite = tenant_member? ? nil : resolve_pending_invite
  end

  def email_item
    satisfied = @current_user.email_verified?
    identity = @current_user.omni_auth_identity
    already_sent = identity&.email_confirmation_sent_at.present?
    cooldown_wait = identity&.email_confirmation_resend_wait || 0
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
      # Disable the resend button while the per-identity cooldown is active.
      # The view wires up a Stimulus controller to re-enable it client-side
      # when the countdown reaches zero, so users don't have to refresh.
      action_disabled: cooldown_wait > 0,
      action_cooldown_seconds: cooldown_wait,
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
