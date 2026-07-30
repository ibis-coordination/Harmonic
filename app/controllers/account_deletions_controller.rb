# typed: false
# frozen_string_literal: true

# Account deletion, both phases of the user-facing flow:
#
# - new/create: the reverification-gated request flow — the confirm page and
#   the submit that starts the grace period. Self-serve only: no API tokens,
#   no representation, humans only.
# - show/restore: the status/restore screen — the only destination a
#   pending-deletion account's session can reach during the grace period (see
#   ApplicationController#check_account_deletion). Serves both scopes: a
#   global pending deletion, and a per-subdomain one on the affected
#   subdomain.
class AccountDeletionsController < ApplicationController
  include RequiresReverification

  # Order matters: reverification is skipped for API tokens, so the
  # self-session check must reject them first.
  before_action :require_self_human_session, only: [:new, :create]
  before_action -> { require_reverification(scope: "account_deletion") }, only: [:new, :create]

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

  def new
    user = T.must(current_user)
    @active_subdomain_count = active_tenant_users(user).count
    @grace_days = (AccountDeletionService::GRACE_PERIOD / 1.day).to_i
    @scrub_date = (Time.current + AccountDeletionService::GRACE_PERIOD).to_date
    @current_subdomain = T.must(current_tenant).subdomain
    # Surfaced on the page so the block is never a surprise at submit time.
    @blocking_handles = AccountDeletionService.sole_admin_blocking_handles(user)
  end

  def create
    user = T.must(current_user)
    if params[:scope] == "subdomain"
      AccountDeletionService.request_tenant_deletion!(user: user, tenant: T.must(current_tenant))
      redirect_to account_deletion_path
    else
      scrub_date = (Time.current + AccountDeletionService::GRACE_PERIOD).to_date
      AccountDeletionService.request_deletion!(user: user, tenant: current_tenant)
      # The request revoked all sessions; end this one cleanly rather than
      # letting the next request bounce with a session-expired message.
      logout_user!
      flash[:notice] = "Your account is scheduled for deletion on #{scrub_date.to_fs(:long)}. " \
                       "Log in before then if you want to restore it."
      redirect_to "/login"
    end
  rescue RuntimeError => e
    flash[:alert] = e.message
    redirect_to new_account_deletion_path
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

  # Deleting an account is strictly self-serve: a human, in a browser session,
  # acting as themselves. API tokens (REST or MCP) and representation sessions
  # are rejected — an agent or trustee must never be able to start a deletion.
  def require_self_human_session
    if api_token_present?
      render plain: "Forbidden", status: :forbidden
      return
    end
    return redirect_to "/login" if current_user.nil?

    user = T.must(current_user)
    return if user.human? && user == current_human_user

    redirect_to "/settings", alert: "You can delete only your own account, and not while representing someone else."
  end

  def active_tenant_users(user)
    TenantUser.for_user_across_tenants(user).where(archived_at: nil, scrubbed_at: nil)
  end

  def pending_tenant_user(user)
    return nil if Tenant.current_id.blank?

    tenant_user = TenantUser.tenant_scoped_only(Tenant.current_id).find_by(user_id: user.id)
    tenant_user&.pending_deletion? ? tenant_user : nil
  end
end
