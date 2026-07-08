# typed: false

# Manage the user's trusted devices (refresh tokens). The list itself is
# rendered inline on the user-settings page; this controller handles the
# write actions: revoke a specific device, or revoke every device except
# the current one.
class DevicesController < ApplicationController
  include SettingsSubjectDefaulting

  before_action :default_settings_handle_to_current_user
  before_action :set_user

  # DELETE /u/:handle/settings/devices/:device_id
  #
  # Revokes the whole token family behind this device. The
  # enforce_refresh_token_revocation before_action on ApplicationController
  # catches the now-revoked cookie on the very next request and logs the user
  # out — including the current device, which lands here on the redirect.
  def destroy
    device = @showing_user.refresh_tokens.live.find_by(id: params[:device_id])
    if device.nil?
      flash[:alert] = "That device is no longer active."
    else
      # A device is a token family (the interactive login plus every silent
      # rotation since). Revoke the whole family, not just the live tail:
      # rotated predecessors keep `revoked_at` nil, and one presented inside
      # its REPLAY_GRACE_WINDOW could re-establish a session on the device the
      # user just signed out. revoke_family! skips already-revoked rows.
      RefreshToken.revoke_family!(device.family_id, reason: "user_logout")
      flash[:notice] = "Signed out of #{device.device_label}."
    end
    redirect_to "/settings"
  end

  # POST /u/:handle/settings/devices/revoke_others
  def revoke_others
    # "Other devices" = the live tails of every family except the current one.
    # Sign out each whole family (tail + rotated predecessors) so nothing in a
    # signed-out family can re-establish a session; count families, not rows.
    other_families = @showing_user.refresh_tokens.live.pluck(:family_id).uniq
    other_families -= [current_refresh_token.family_id] if current_refresh_token
    @showing_user.refresh_tokens
                 .where(family_id: other_families, revoked_at: nil)
                 .update_all(revoked_at: Time.current, revoked_reason: "user_logout")
    count = other_families.size
    flash[:notice] = "Signed out of #{count} other #{'device'.pluralize(count)}."
    redirect_to "/settings"
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
