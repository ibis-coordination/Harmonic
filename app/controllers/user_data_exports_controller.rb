# typed: false

# Per-user data export: a user downloads a ZIP of records that would be deleted
# or scrubbed on their account closure. See `.claude/plans/per-user-data-export.md`.
class UserDataExportsController < ApplicationController
  include RequiresReverification
  include SettingsSubjectDefaulting

  before_action :default_settings_handle_to_current_user
  before_action :reject_api_token_auth
  before_action :require_login
  before_action :require_feature_enabled
  before_action :set_settings_user
  before_action :require_owner
  before_action :require_human_user
  before_action -> { require_reverification(scope: "data_transfer") }

  # GET /u/:handle/settings/data-export
  def index
    @exports = DataExport
                 .where(user_id: @settings_user.id, tenant_id: @current_tenant.id)
                 .user_exports
                 .order(created_at: :desc)
  end

  # POST /u/:handle/settings/data-export
  def create
    if DataExport.user_exports.active.exists?(user_id: @settings_user.id, tenant_id: @current_tenant.id)
      flash[:alert] = "An export is already in progress. Please wait for it to finish before starting another."
      return redirect_to user_data_export_path
    end

    data_export = DataExport.create!(
      tenant: @current_tenant,
      collective: @current_tenant.main_collective,
      user: @settings_user,
      status: "pending",
      export_type: "user",
    )
    UserDataExportJob.perform_later(data_export.id)

    SecurityAuditLog.log_user_action(
      user: @settings_user,
      ip: request.remote_ip,
      action: "user_data_export_created",
      details: { export_id: data_export.id, tenant_id: @current_tenant.id },
    )

    flash[:notice] = "Your export is being prepared. You'll receive an email when it's ready."
    redirect_to user_data_export_path
  end

  # GET /u/:handle/settings/data-export/:export_id
  def download
    data_export = DataExport
                    .user_exports
                    .where(user_id: @settings_user.id, tenant_id: @current_tenant.id)
                    .find_by(id: params[:export_id])

    return render plain: "Not Found", status: :not_found if data_export.nil?

    unless data_export.downloadable?
      flash[:alert] = data_export.expired? ? "This export has expired." : "This export is not ready for download."
      return redirect_to user_data_export_path
    end

    SecurityAuditLog.log_user_action(
      user: @settings_user,
      ip: request.remote_ip,
      action: "user_data_export_downloaded",
      details: { export_id: data_export.id, tenant_id: @current_tenant.id },
    )

    redirect_to rails_blob_path(data_export.file, disposition: "attachment", expires_in: 5.minutes), allow_other_host: true
  end

  private

  # Personal data export is browser-only by design. The reverification gate
  # (2FA) intentionally bypasses for API-token requests, but for a flow this
  # sensitive — a download of everything the user has ever shared — we
  # require an interactive browser session with a fresh 2FA confirmation.
  # A stolen API token (even one issued by the legitimate user) must not be
  # able to download a personal export without 2FA.
  def reject_api_token_auth
    return unless api_token_present?

    render plain: "API tokens cannot trigger personal data exports. Sign in via the web UI.", status: :forbidden
  end

  def require_login
    return if @current_user

    redirect_to "/login"
  end

  def require_feature_enabled
    return if @current_tenant&.feature_enabled?("user_data_export")

    render plain: "Not Found", status: :not_found
  end

  def set_settings_user
    tu = @current_tenant.tenant_users.find_by(handle: params[:handle])
    @settings_user = tu&.user
    render plain: "Not Found", status: :not_found unless @settings_user
  end

  # Self-service only: a user can only export their own data. No admin override.
  def require_owner
    return if @current_user == @settings_user

    render plain: "Forbidden", status: :forbidden
  end

  # AI agents and collective_identity users have their data included in their
  # parent's export rather than their own.
  def require_human_user
    return if @current_user&.user_type == "human"

    render plain: "Forbidden", status: :forbidden
  end

  def user_data_export_path
    "/settings/data-export"
  end
end
