# typed: false

# TenantAdminController handles single-tenant administration.
#
# Access: Accessible from any tenant by users with admin role on TenantUser.
#
# Features:
# - Tenant settings (name, timezone, feature flags)
# - User management (scoped to current tenant, using handles)
#
# This is distinct from:
# - SystemAdminController: Manages system infrastructure (Sidekiq, monitoring)
# - AppAdminController: Manages tenants and users across ALL tenants (including suspension)
class TenantAdminController < ApplicationController
  include RequiresReverification

  before_action :ensure_tenant_admin
  before_action -> { require_reverification(scope: "admin") }
  before_action :ensure_ai_agent_admin_access
  before_action :block_ai_agent_admin_writes_in_production
  before_action :set_sidebar_mode

  USERS_PER_PAGE = 50
  MAX_IMPORT_SIZE_BYTES = ENV.fetch("MAX_IMPORT_SIZE_BYTES", 2.gigabytes.to_i).to_i

  # GET /tenant-admin
  def dashboard
    @page_title = 'Tenant Admin'
    @team = @current_tenant.team
    respond_to do |format|
      format.html
      format.md
    end
  end

  # ============================================================================
  # Tenant Settings
  # ============================================================================

  # GET /tenant-admin/settings
  def settings
    @page_title = 'Tenant Settings'
    respond_to do |format|
      format.html
      format.md
    end
  end

  # POST /tenant-admin/settings
  def update_settings
    @current_tenant.name = params[:name] if params[:name].present?
    @current_tenant.timezone = params[:timezone] if params[:timezone].present?

    # Handle non-feature-flag settings
    ["require_login"].each do |setting|
      if ["true", "false", "1", "0"].include?(params[setting])
        @current_tenant.settings[setting] = params[setting] == "true" || params[setting] == "1"
      end
    end

    # Allowed attachment categories (array of "images" / "pdfs" / "text").
    # The setter intersects against the valid set, so empty strings from the
    # hidden marker field and any unknown values are dropped.
    if params.key?(:allowed_attachment_categories)
      @current_tenant.allowed_attachment_categories = params[:allowed_attachment_categories]
    end

    # Handle feature flags via unified system
    FeatureFlagService.all_flags.each do |flag_name|
      param_key = "feature_#{flag_name}"
      if params.key?(param_key) || params.key?(flag_name)
        # Accept both feature_api and api (legacy) param names
        value = params[param_key] || params[flag_name]
        enabled = value == "true" || value == "1" || value == true
        @current_tenant.settings["feature_flags"] ||= {}
        @current_tenant.settings["feature_flags"][flag_name] = enabled
      end
    end

    @current_tenant.save!
    redirect_to "/tenant-admin"
  end

  # ============================================================================
  # User Management (Scoped to Current Tenant)
  # ============================================================================

  # GET /tenant-admin/users
  def users
    @page_title = 'Users'
    @search_query = params[:q].to_s.strip
    @page = [(params[:page].to_i), 1].max
    @per_page = USERS_PER_PAGE

    base_scope = @current_tenant.users
      .includes(:tenant_users)
      .where.not(user_type: 'trustee')

    if @search_query.present?
      sanitized = ActiveRecord::Base.sanitize_sql_like(@search_query)
      base_scope = base_scope.where("email ILIKE ?", "%#{sanitized}%")
    end

    # Get counts for each user type
    @counts_by_type = base_scope.group(:user_type).count

    # Calculate offset
    offset = (@page - 1) * @per_page

    # Get paginated users ordered by name
    paginated_users = base_scope.order(:name).limit(@per_page).offset(offset)
    @users_by_type = paginated_users.group_by(&:user_type)

    # Calculate total and pagination info
    @total_users = @counts_by_type.values.sum
    @total_pages = (@total_users.to_f / @per_page).ceil
    @total_pages = 1 if @total_pages < 1

    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /tenant-admin/users/:handle
  def show_user
    @showing_user = find_user_by_handle(params[:handle])
    return render(plain: "404 Not Found", status: :not_found) unless @showing_user
    @page_title = @showing_user.display_name || @showing_user.name
    @is_admin = @current_tenant.is_admin?(@showing_user)
    respond_to do |format|
      format.html
      format.md
    end
  end

  # ============================================================================
  # Data Import Actions
  # ============================================================================

  # GET /tenant-admin/imports
  def imports_index
    @imports = DataImport.tenant_scoped_only(@current_tenant.id).order(created_at: :desc)
    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /tenant-admin/imports/new
  def new_import
    @import = DataImport.new
  end

  # POST /tenant-admin/imports
  def create_import
    if params[:file].blank?
      flash[:alert] = "Please select a ZIP file to import."
      return redirect_to "/tenant-admin/imports/new"
    end

    if params[:file].size > MAX_IMPORT_SIZE_BYTES
      flash[:alert] = "File too large. Maximum size is #{MAX_IMPORT_SIZE_BYTES / 1.gigabyte} GB."
      return redirect_to "/tenant-admin/imports/new"
    end

    unless valid_zip_upload?(params[:file])
      flash[:alert] = "File must be a valid ZIP archive."
      return redirect_to "/tenant-admin/imports/new"
    end

    if DataImport.tenant_scoped_only(@current_tenant.id).active.exists?
      flash[:alert] = "An import is already in progress for this tenant."
      return redirect_to "/tenant-admin/imports"
    end

    handle_email_map, parse_error = parse_handle_email_map(params[:user_map])
    if parse_error
      flash[:alert] = parse_error
      return redirect_to "/tenant-admin/imports/new"
    end

    import_options = {
      "use_placeholders" => params[:use_placeholders] == "1",
      "handle_email_map" => handle_email_map,
    }

    data_import = DataImport.create!(
      tenant: @current_tenant,
      user: @current_user,
      status: "pending",
      import_options: import_options
    )
    data_import.file.attach(params[:file])
    CollectiveImportJob.perform_later(data_import.id)

    SecurityAuditLog.log_admin_action(
      admin: @current_user,
      ip: request.remote_ip,
      action: "data_import_created",
      details: { import_id: data_import.id }
    )

    flash[:notice] = "Your import is being processed. This page will update when it's complete."
    redirect_to "/tenant-admin/imports/#{data_import.id}"
  end

  # GET /tenant-admin/imports/:id
  def show_import
    @import = DataImport.tenant_scoped_only(@current_tenant.id).find(params[:id])
    respond_to do |format|
      format.html
      format.md
    end
  end

  # ============================================================================
  # Markdown API Actions
  # ============================================================================

  def actions_index
    @page_title = "Actions | Tenant Admin"
    render_actions_index(ActionsHelper.actions_for_route('/tenant-admin'))
  end

  def actions_index_settings
    @page_title = "Actions | Tenant Settings"
    render_actions_index(ActionsHelper.actions_for_route('/tenant-admin/settings'))
  end

  def describe_update_settings
    render_action_description(ActionsHelper.action_description("update_tenant_settings"))
  end

  def execute_update_settings
    @current_tenant.name = params[:name] if params[:name].present?
    @current_tenant.timezone = params[:timezone] if params[:timezone].present?

    # Handle non-feature-flag settings
    ["require_login"].each do |setting|
      if ["true", "false", "1", "0"].include?(params[setting])
        @current_tenant.settings[setting] = params[setting] == "true" || params[setting] == "1"
      end
    end

    # Allowed attachment categories (array of "images" / "pdfs" / "text").
    # The setter intersects against the valid set, so empty strings from the
    # hidden marker field and any unknown values are dropped.
    if params.key?(:allowed_attachment_categories)
      @current_tenant.allowed_attachment_categories = params[:allowed_attachment_categories]
    end

    # Handle feature flags via unified system
    FeatureFlagService.all_flags.each do |flag_name|
      param_key = "feature_#{flag_name}"
      if params.key?(param_key) || params.key?(flag_name)
        # Accept both feature_api and api (legacy) param names
        value = params[param_key] || params[flag_name]
        enabled = value == "true" || value == "1" || value == true
        @current_tenant.settings["feature_flags"] ||= {}
        @current_tenant.settings["feature_flags"][flag_name] = enabled
      end
    end

    @current_tenant.save!

    respond_to do |format|
      format.md { render "settings" }
      format.html { redirect_to "/tenant-admin" }
    end
  end

  private

  # Validates that an uploaded file is a ZIP by checking the magic bytes.
  # Content-Type is intentionally not checked — it's browser-supplied and
  # easily spoofed; the byte signature is the authoritative test.
  def valid_zip_upload?(uploaded_file)
    magic = uploaded_file.read(4)
    uploaded_file.rewind
    # "PK\x03\x04" = local file header (normal ZIP)
    # "PK\x05\x06" = end of central directory (empty ZIP)
    magic == "PK\x03\x04" || magic == "PK\x05\x06"
  end

  MAX_USER_MAP_BYTES = 1.megabyte

  # Parses an optional handle→email JSON map uploaded by the importing admin.
  # Returns [parsed_hash, error_message]. parsed_hash is {} if no file given.
  def parse_handle_email_map(uploaded_file)
    return [{}, nil] if uploaded_file.blank?

    if uploaded_file.size > MAX_USER_MAP_BYTES
      return [nil, "User mapping file too large (max #{MAX_USER_MAP_BYTES / 1.kilobyte} KB)."]
    end

    parsed = JSON.parse(uploaded_file.read)
    uploaded_file.rewind

    unless parsed.is_a?(Hash) && parsed.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
      return [nil, "User mapping file must be a JSON object of {\"handle\": \"email\"}."]
    end

    [parsed, nil]
  rescue JSON::ParserError => e
    [nil, "User mapping file is not valid JSON: #{e.message}"]
  end

  def ensure_tenant_admin
    unless @current_tenant.is_admin?(@current_user)
      @sidebar_mode = 'none'
      render status: :forbidden, layout: 'application', template: 'tenant_admin/403_not_admin'
    end
  end

  def ensure_ai_agent_admin_access
    return true unless @current_user&.ai_agent?
    # AI agent must be admin AND parent must also be admin
    unless @current_tenant.is_admin?(@current_user) && @current_user.parent && @current_tenant.is_admin?(@current_user.parent)
      return render status: 403, plain: '403 Unauthorized - AI agent admin access requires both AI agent and parent to be admins'
    end
    true
  end

  def block_ai_agent_admin_writes_in_production
    return true unless @current_user&.ai_agent?
    return true unless production_environment?
    # In production, AI agents can only read admin pages, not write
    if request.method != 'GET'
      return render status: 403, plain: '403 Unauthorized - AI agents cannot perform admin write operations in production'
    end
    true
  end

  # Helper method for views to determine if actions should be shown
  # Returns false for AI agents in production (they can't perform writes)
  def can_perform_admin_actions?
    return false unless @current_tenant.is_admin?(@current_user)
    return false if @current_user&.ai_agent? && production_environment?
    true
  end
  helper_method :can_perform_admin_actions?

  # Extracted to allow testing with production environment simulation
  # In tests, set Thread.current[:simulate_production] = true to simulate production
  def production_environment?
    return true if Thread.current[:simulate_production]
    Rails.env.production?
  end

  def set_sidebar_mode
    @sidebar_mode = 'tenant_admin'
  end

  def find_user_by_handle(handle)
    tenant_user = @current_tenant.tenant_users.find_by(handle: handle)
    return nil unless tenant_user
    tenant_user.user
  end

  # Override to prevent ApplicationController from trying to constantize "TenantAdmin"
  def current_resource_model
    Tenant
  end

  def current_resource
    @current_tenant
  end
end
