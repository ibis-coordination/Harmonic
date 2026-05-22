# typed: false

# Two-step signup flow for users who arrive at a tenant without an existing
# TenantUser record on a require_invite tenant:
#
#   1. /invite-required (GET)         — landing page with invite-code form
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
  def invite_required
    return redirect_to "/login" unless @current_user
    return redirect_to root_path if @current_tenant.tenant_users.exists?(user: @current_user)

    render_landing
  end

  def confirm_invite
    return redirect_to "/login" unless @current_user
    return redirect_to root_path if @current_tenant.tenant_users.exists?(user: @current_user)

    invite = lookup_invite(params[:code])
    if invite&.is_acceptable_by_user?(@current_user)
      @invite = invite
      @sidebar_mode = "none"
      @hide_header = true
      @page_title = "Confirm invite | #{@current_tenant.name}"
      render "signup/confirm_invite", layout: "application"
    else
      flash.now[:alert] = "That invite code is not valid or has expired."
      render_landing(status: :unprocessable_entity)
    end
  end

  def accept_invite
    return redirect_to "/login" unless @current_user

    invite = lookup_invite(params[:code])
    unless invite&.is_acceptable_by_user?(@current_user)
      flash[:alert] = "That invite code is not valid or has expired."
      return redirect_to invite_required_path
    end

    # Tenant add is conditional so this action is idempotent even if the user
    # became a tenant member between the confirm step and the accept (race or
    # admin add). In either case we still want the collective join to happen.
    ActiveRecord::Base.transaction do
      @current_tenant.add_user!(@current_user) unless @current_tenant.tenant_users.exists?(user: @current_user)
      @current_user.accept_invite!(invite)
    end

    redirect_to invite.collective.path
  end

  private

  def lookup_invite(raw_code)
    code = raw_code.to_s.strip
    return nil if code.blank?

    Invite.tenant_scoped_only(@current_tenant.id).find_by(code: code)
  end

  def render_landing(status: :ok)
    @sidebar_mode = "none"
    @hide_header = true
    @page_title = "Invite required | #{@current_tenant.name}"
    render "signup/invite_required", layout: "application", status: status
  end

  # Treated as an auth-flow controller so it's exempt from the billing gate,
  # collective-archived gate, and login-required filter. New users have not
  # yet joined the tenant, so requiring billing or collective context before
  # they can accept an invite would create a redirect loop.
  def is_auth_controller?
    true
  end
end
