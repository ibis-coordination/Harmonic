# typed: false

# Two-step signup flow for users who arrive at a tenant without an existing
# TenantUser record on a require_invite tenant:
#
#   1. /invite-required (GET)         — landing page with invite-code form.
#                                       With a usable code (?code= param or
#                                       the per-tenant session stash written
#                                       by the login callback — see
#                                       PendingInviteStash), skips straight
#                                       to the confirmation page.
#   2. /invite-required (POST)        — validate code, render confirmation
#                                       page showing the collective + tenant
#                                       the user is about to join. No
#                                       membership is created yet.
#   3. /invite-required/accept (POST) — atomic tenant + collective join,
#                                       redirect to the collective homepage.
#
# Splitting validate and accept gives the user a "wait, what am I joining?"
# beat before they commit, and lets us keep both writes inside a single
# transaction so we never leave an orphan TenantUser if collective join
# fails.
class SignupController < ApplicationController
  include BotProtection

  # Honeypot only: user already passed Turnstile at /login or /register.
  protect_from_bots only: [:confirm_invite, :accept_invite], turnstile: false

  def invite_required
    return redirect_to "/login" unless @current_user
    return redirect_to root_path if @current_tenant.tenant_users.exists?(user: @current_user)

    # The login callback and invite links land here with ?code=, and the
    # session carries a pending code for users who wandered off mid-flow.
    # Either way, skip straight to the confirmation page so the user doesn't
    # have to re-type a code we already know. A dead ?code= param must not
    # shadow a still-valid pending invite, so fall back to the session stash
    # (which self-clears codes that no longer resolve).
    invite = acceptable_invite_from(params[:code]) || resolve_pending_invite
    if invite
      stash_pending_invite!(invite)
      render_confirmation(invite)
    else
      render_landing
    end
  end

  def confirm_invite
    return redirect_to "/login" unless @current_user
    return redirect_to root_path if @current_tenant.tenant_users.exists?(user: @current_user)

    invite = acceptable_invite_from(params[:code])
    if invite
      stash_pending_invite!(invite)
      render_confirmation(invite)
    else
      flash.now[:alert] = "That invite code is not valid or has expired."
      render_landing(status: :unprocessable_entity)
    end
  end

  def accept_invite
    return redirect_to "/login" unless @current_user

    invite = acceptable_invite_from(params[:code])
    unless invite
      flash[:alert] = "That invite code is not valid or has expired."
      return redirect_to invite_required_path
    end

    # Funded to join: accepting a funding-collective invite is consenting to
    # have your own balance drawn on, so it carries the same billing
    # requirement as the in-app accept path. Gate before the join transaction
    # so a blocked accept doesn't create the TenantUser either.
    if invite.collective.agent_funding? && !@current_user.funded_billing?
      flash[:alert] = "Joining #{invite.collective.name} means consenting to fund its agents from your own prepaid balance, " \
                      "which requires active billing with prepaid credits."
      return redirect_to invite_required_path
    end

    requested_handle = params[:handle].presence
    retried = false
    begin
      # Tenant add is conditional so this action is idempotent even if the
      # user became a tenant member between the confirm step and the accept
      # (race or admin add). Either way the collective join still happens.
      ActiveRecord::Base.transaction do
        @current_tenant.add_user!(@current_user, handle: requested_handle) unless @current_tenant.tenant_users.exists?(user: @current_user)
        @current_user.accept_invite!(invite)
      end
    rescue ActiveRecord::RecordNotUnique
      # The handle validation passed on both sides of a race and the DB
      # unique index fired — same suggested handle submitted concurrently,
      # or a double-click racing itself on the membership indexes. One
      # retry: a now-member skips add_user!, and a genuine handle collision
      # surfaces as the friendly RecordInvalid below.
      raise if retried

      retried = true
      retry
    end
    clear_pending_invite!

    redirect_to invite.collective.path
  rescue ActiveRecord::RecordInvalid => e
    # Only handle errors the confirmation page can actually fix (the
    # handle); anything else from the join transaction must not be
    # misattributed to the handle picker.
    raise unless e.record.is_a?(TenantUser)

    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    @suggested_handle = params[:handle].to_s.parameterize.presence
    render_confirmation(invite, status: :unprocessable_entity)
  end

  private

  def lookup_invite(raw_code)
    code = raw_code.to_s.strip
    return nil if code.blank?

    Invite.tenant_scoped_only(@current_tenant.id).find_by(code: code)
  end

  def acceptable_invite_from(raw_code)
    invite = lookup_invite(raw_code)
    invite if invite&.is_acceptable_by_user?(@current_user)
  end

  def render_confirmation(invite, status: :ok)
    @invite = invite
    @suggested_handle ||= TenantUser.default_handle_for(tenant_id: @current_tenant.id, user: @current_user)
    @sidebar_mode = "none"
    @hide_header = true
    @page_title = "Confirm invite | #{@current_tenant.name}"
    render_signup_page("signup/confirm_invite", status: status)
  end

  def render_landing(status: :ok)
    @sidebar_mode = "none"
    @hide_header = true
    @page_title = "Invite required | #{@current_tenant.name}"
    render_signup_page("signup/invite_required", status: status)
  end

  # The markdown variants skip the application layout: its nav (user path,
  # notification counts) presumes tenant membership, which signup pages
  # exist precisely to establish. They carry their own minimal frontmatter.
  def render_signup_page(template, status:)
    respond_to do |format|
      format.html { render template, layout: "application", status: status }
      format.md { render template, layout: false, status: status }
    end
  end

  # Treated as an auth-flow controller so it's exempt from the billing gate,
  # collective-archived gate, and login-required filter. New users have not
  # yet joined the tenant, so requiring billing or collective context before
  # they can accept an invite would create a redirect loop.
  def is_auth_controller?
    true
  end
end
