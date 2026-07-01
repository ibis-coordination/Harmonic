# typed: true

# Manage the user's Web Push subscriptions (device registrations). The device
# list is rendered inline on the user-settings page; the JS subscribe flow
# POSTs the browser's PushSubscription here.
class WebPushSubscriptionsController < ApplicationController
  extend T::Sig

  before_action :require_web_push_enabled
  before_action :set_user

  # POST /u/:handle/settings/push-subscriptions
  #
  # A push subscription is minted by the requesting browser, so it can only
  # ever belong to the user actually driving it — not to a user a trustee is
  # managing. Hence the stricter-than-devices gate: self only.
  def create
    return head :forbidden unless @showing_user.id == current_user.id
    return head :forbidden unless current_user.human?

    subscription_params = params.require(:subscription)
    subscription = WebPushSubscription.upsert_for!(
      user: current_user,
      endpoint: subscription_params.require(:endpoint),
      p256dh_key: subscription_params.require(:keys).require(:p256dh),
      auth_key: subscription_params.require(:keys).require(:auth),
      request: request
    )

    render json: { id: subscription.id, device_label: subscription.device_label }, status: :created
  end

  # DELETE /u/:handle/settings/push-subscriptions/:subscription_id
  def destroy
    subscription = @showing_user.web_push_subscriptions.active.find_by(id: params[:subscription_id])
    if subscription.nil?
      flash[:alert] = "That push device is no longer active."
    else
      subscription.revoke!(reason: "user")
      flash[:notice] = "Push notifications disabled for #{subscription.device_label.presence || "that device"}."
    end
    redirect_to "#{@showing_user.path}/settings"
  end

  private

  sig { void }
  def require_web_push_enabled
    head :not_found unless FeatureFlagService.enabled?("web_push", tenant: current_tenant)
  end

  sig { void }
  def set_user
    handle = params[:handle]
    tu = current_tenant.tenant_users.find_by(handle: handle)
    return render status: :not_found, plain: "404 user not found" if tu.nil?
    return render status: :forbidden, plain: "403 Unauthorized" unless current_user.can_edit?(tu.user)

    @showing_user = tu.user
    @showing_user.tenant_user = tu
  end
end
