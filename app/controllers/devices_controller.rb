# typed: false

# Manage the user's trusted devices (refresh tokens). The list itself is
# rendered inline on the user-settings page; this controller handles the
# write actions: revoke a specific device, or revoke every device except
# the current one.
class DevicesController < ApplicationController
  before_action :set_user

  # DELETE /u/:handle/settings/devices/:device_id
  #
  # Just revokes the token. The enforce_refresh_token_revocation
  # before_action on ApplicationController catches the now-revoked cookie
  # on the very next request and logs the user out — including the
  # current device, which lands here on the redirect.
  def destroy
    device = @showing_user.refresh_tokens.active.find_by(id: params[:device_id])
    if device.nil?
      flash[:alert] = "That device is no longer active."
    else
      device.revoke!(reason: "user_logout")
      flash[:notice] = "Signed out of #{device.device_label}."
    end
    redirect_to "#{@showing_user.path}/settings"
  end

  # POST /u/:handle/settings/devices/revoke_others
  def revoke_others
    scope = @showing_user.refresh_tokens.active
    scope = scope.where.not(id: current_refresh_token.id) if current_refresh_token
    count = scope.update_all(revoked_at: Time.current, revoked_reason: "user_logout")
    flash[:notice] = "Signed out of #{count} other #{'device'.pluralize(count)}."
    redirect_to "#{@showing_user.path}/settings"
  end

  private

  def set_user
    handle = params[:handle]
    tu = current_tenant.tenant_users.find_by(handle: handle)
    return render status: :not_found, plain: "404 user not found" if tu.nil?
    return render status: :forbidden, plain: "403 Unauthorized" unless current_user.can_edit?(tu.user)

    @showing_user = tu.user
    @showing_user.tenant_user = tu
  end
end
