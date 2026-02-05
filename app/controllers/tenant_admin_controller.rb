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
  before_action :ensure_tenant_admin
  before_action :ensure_subagent_admin_access
  before_action :block_subagent_admin_writes_in_production
  before_action :set_sidebar_mode

  USERS_PER_PAGE = 50

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
      base_scope = base_scope.where("email ILIKE ?", "%#{@search_query}%")
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

  def ensure_tenant_admin
    unless @current_tenant.is_admin?(@current_user)
      @sidebar_mode = 'none'
      render status: :forbidden, layout: 'application', template: 'tenant_admin/403_not_admin'
    end
  end

  def ensure_subagent_admin_access
    return true unless @current_user&.subagent?
    # Subagent must be admin AND parent must also be admin
    unless @current_tenant.is_admin?(@current_user) && @current_user.parent && @current_tenant.is_admin?(@current_user.parent)
      return render status: 403, plain: '403 Unauthorized - Subagent admin access requires both subagent and parent to be admins'
    end
    true
  end

  def block_subagent_admin_writes_in_production
    return true unless @current_user&.subagent?
    return true unless production_environment?
    # In production, subagents can only read admin pages, not write
    if request.method != 'GET'
      return render status: 403, plain: '403 Unauthorized - Subagents cannot perform admin write operations in production'
    end
    true
  end

  # Helper method for views to determine if actions should be shown
  # Returns false for subagents in production (they can't perform writes)
  def can_perform_admin_actions?
    return false unless @current_tenant.is_admin?(@current_user)
    return false if @current_user&.subagent? && production_environment?
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
