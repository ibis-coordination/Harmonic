# typed: true
# frozen_string_literal: true

# The deletion status/restore screen — the only destination a
# pending-deletion account's session can reach during the grace period (see
# ApplicationController#check_account_deletion). Serves both scopes: a global
# pending deletion, and a per-subdomain one on the affected subdomain.
class AccountDeletionsController < ApplicationController
  def show
    user = current_user
    return redirect_to "/" if user.nil?

    if user.pending_deletion?
      @scope = :global
      @scrub_date = T.must(user.deletion_requested_at) + AccountDeletionService::GRACE_PERIOD
    elsif (tenant_user = pending_tenant_user(user))
      @scope = :subdomain
      @subdomain = Tenant.find(tenant_user.tenant_id).subdomain
      @scrub_date = T.must(tenant_user.deletion_requested_at) + AccountDeletionService::GRACE_PERIOD
    else
      redirect_to "/"
    end
  end

  def restore
    user = current_user
    return redirect_to "/" if user.nil?

    if user.pending_deletion?
      AccountDeletionService.restore!(user: user)
      redirect_to "/", notice: "Your account has been restored."
    elsif (tenant_user = pending_tenant_user(user))
      AccountDeletionService.restore_tenant!(user: user, tenant: Tenant.find(tenant_user.tenant_id))
      redirect_to "/", notice: "Your account on this subdomain has been restored."
    else
      redirect_to "/"
    end
  end

  private

  def pending_tenant_user(user)
    return nil if Tenant.current_id.blank?

    tenant_user = TenantUser.tenant_scoped_only(Tenant.current_id).find_by(user_id: user.id)
    tenant_user&.pending_deletion? ? tenant_user : nil
  end
end
