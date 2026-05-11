# typed: false

class CollectiveDataTransfersController < ApplicationController
  include RequiresReverification

  before_action :reject_api_token_auth
  before_action :require_export_feature_enabled
  before_action :require_admin
  before_action -> { require_reverification(scope: "data_transfer") }

  # GET /collectives/:collective_handle/exports
  def exports_index
    @exports = DataExport.where(collective_id: @current_collective.id).order(created_at: :desc)
  end

  # POST /collectives/:collective_handle/exports
  def create_export
    # Rate limit: only 1 active export per collective
    if DataExport.active.exists?(collective_id: @current_collective.id)
      flash[:alert] = "An export is already in progress for this collective."
      return redirect_to collective_exports_path
    end

    data_export = DataExport.create!(
      tenant: @current_tenant,
      collective: @current_collective,
      user: @current_user,
      status: "pending"
    )
    CollectiveExportJob.perform_later(data_export.id)

    SecurityAuditLog.log_admin_action(
      admin: @current_user,
      ip: request.remote_ip,
      action: "data_export_created",
      details: { collective_id: @current_collective.id, collective_name: @current_collective.name, export_id: data_export.id },
    )

    flash[:notice] = "Your export is being prepared. This page will update when it's ready."
    redirect_to collective_exports_path
  end

  # GET /collectives/:collective_handle/exports/:id
  def download_export
    data_export = DataExport.find_by!(id: params[:id], collective_id: @current_collective.id)

    unless data_export.downloadable?
      flash[:alert] = data_export.expired? ? "This export has expired." : "This export is not ready for download."
      return redirect_to collective_exports_path
    end

    SecurityAuditLog.log_admin_action(
      admin: @current_user,
      ip: request.remote_ip,
      action: "data_export_downloaded",
      details: { collective_id: @current_collective.id, export_id: data_export.id },
    )

    redirect_to rails_blob_path(data_export.file, disposition: "attachment", expires_in: 5.minutes), allow_other_host: true
  end

  private

  # Collective data export is browser-only by design. The reverification gate
  # (2FA) intentionally bypasses for API-token requests, but exporting an
  # entire collective's data must require an interactive browser session
  # with a fresh 2FA confirmation. A stolen API token (even one with
  # admin-level scope) must not be able to trigger or download an export.
  def reject_api_token_auth
    return unless api_token_present?

    render plain: "API tokens cannot trigger data exports. Sign in via the web UI.", status: :forbidden
  end

  def require_export_feature_enabled
    return if @current_tenant&.feature_enabled?("collective_export")

    render plain: "Not Found", status: :not_found
  end

  def require_admin
    return if @current_user&.collective_member&.is_admin?

    flash[:alert] = "You must be an admin to access data transfers."
    redirect_to root_path
  end

  def collective_path_prefix
    @current_collective.path
  end

  def collective_exports_path
    "#{collective_path_prefix}/exports"
  end
end
