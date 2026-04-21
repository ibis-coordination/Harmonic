# typed: false

# AppAdminController handles application-level administration.
#
# Access: Only accessible from the primary tenant by users with the app_admin global role.
#
# Features:
# - Tenant management (create, list, view, suspend/unsuspend)
# - User management across ALL tenants (unscoped queries)
# - User suspension/unsuspension
# - Cross-tenant user viewing (show which tenants a user belongs to)
# - Security audit dashboard
#
# This is distinct from:
# - SystemAdminController: Manages system infrastructure (Sidekiq, monitoring)
# - TenantAdminController: Manages a single tenant's settings and users
class AppAdminController < ApplicationController
  include RequiresReverification

  before_action :ensure_primary_tenant
  before_action :ensure_app_admin
  before_action -> { require_reverification(scope: "admin") }
  before_action :set_sidebar_mode

  USERS_PER_PAGE = 50

  # GET /app-admin
  def dashboard
    @page_title = 'App Admin'
    @total_tenants = Tenant.count
    @total_users = User.where.not(user_type: 'trustee').count
    respond_to do |format|
      format.html
      format.md
    end
  end

  # ============================================================================
  # Tenant Management
  # ============================================================================

  # GET /app-admin/tenants
  def tenants
    @page_title = 'All Tenants'
    @tenants = Tenant.order(:name)
    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /app-admin/tenants/new
  def new_tenant
    @page_title = 'New Tenant'
    respond_to do |format|
      format.html
      format.md
    end
  end

  # POST /app-admin/tenants
  def create_tenant
    tenant_params = params[:tenant] || params
    t = Tenant.new
    t.subdomain = tenant_params[:subdomain]
    t.name = tenant_params[:name]
    t.save!
    t.create_main_collective!(created_by: @current_user)
    tu = t.add_user!(@current_user)
    tu.add_role!('admin')
    redirect_to "/app-admin/tenants/#{t.subdomain}/complete"
  end

  # GET /app-admin/tenants/:subdomain/complete
  def complete_tenant_creation
    @tenant = Tenant.find_by(subdomain: params[:subdomain])
    return render(plain: "404 Not Found", status: :not_found) unless @tenant
    @page_title = 'Tenant Created'
    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /app-admin/tenants/:subdomain
  def show_tenant
    @showing_tenant = Tenant.find_by(subdomain: params[:subdomain])
    return render(plain: "404 Not Found", status: :not_found) unless @showing_tenant
    @current_user_is_admin_of_showing_tenant = @showing_tenant.is_admin?(@current_user)
    @page_title = @showing_tenant.name
    respond_to do |format|
      format.html
      format.md
    end
  end

  # ============================================================================
  # User Management (All Users Across All Tenants)
  # ============================================================================

  # GET /app-admin/users
  def users
    @page_title = 'All Users'
    @search_query = params[:q].to_s.strip
    @page = [(params[:page].to_i), 1].max
    @per_page = USERS_PER_PAGE

    base_scope = User.where.not(user_type: 'trustee')

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

  # GET /app-admin/users/:id
  def show_user
    @showing_user = User.find_by(id: params[:id])
    return render(plain: "404 Not Found", status: :not_found) unless @showing_user
    @page_title = @showing_user.display_name || @showing_user.name
    # Get all tenants this user belongs to
    @user_tenants = @showing_user.tenant_users.includes(:tenant).map(&:tenant)
    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /app-admin/users/:id/actions/suspend_user
  def describe_suspend_user
    @showing_user = User.find_by(id: params[:id])
    return render(plain: "404 Not Found", status: :not_found) unless @showing_user
    render_action_description(ActionsHelper.action_description("suspend_user"))
  end

  # POST /app-admin/users/:id/actions/suspend_user
  def execute_suspend_user
    user = User.find_by(id: params[:id])
    return render(plain: "404 Not Found", status: :not_found) unless user

    # Prevent self-suspension
    if user.id == @current_user.id
      respond_to do |format|
        format.md { render plain: 'You cannot suspend your own account.', status: 400 }
        format.html do
          flash[:alert] = 'You cannot suspend your own account.'
          redirect_to "/app-admin/users/#{user.id}"
        end
      end
      return
    end

    reason = params[:reason].presence || 'No reason provided'
    user.suspend!(by: @current_user, reason: reason)
    SecurityAuditLog.log_user_suspended(
      user: user,
      suspended_by: @current_user,
      reason: reason,
      ip: request.remote_ip
    )

    respond_to do |format|
      format.md do
        @showing_user = user.reload
        @page_title = @showing_user.display_name || @showing_user.name
        @user_tenants = @showing_user.tenant_users.includes(:tenant).map(&:tenant)
        render 'show_user'
      end
      format.html do
        flash[:notice] = "User #{user.display_name} has been suspended."
        redirect_to "/app-admin/users/#{user.id}"
      end
    end
  end

  # GET /app-admin/users/:id/actions/unsuspend_user
  def describe_unsuspend_user
    @showing_user = User.find_by(id: params[:id])
    return render(plain: "404 Not Found", status: :not_found) unless @showing_user
    render_action_description(ActionsHelper.action_description("unsuspend_user"))
  end

  # POST /app-admin/users/:id/actions/unsuspend_user
  def execute_unsuspend_user
    user = User.find_by(id: params[:id])
    return render(plain: "404 Not Found", status: :not_found) unless user

    user.unsuspend!

    # Sync billing if unsuspending an AI agent
    if user.ai_agent? && user.parent_id.present?
      parent = User.find_by(id: user.parent_id)
      if parent
        StripeService.sync_subscription_quantity!(parent)
      end
    end

    SecurityAuditLog.log_user_unsuspended(
      user: user,
      unsuspended_by: @current_user,
      ip: request.remote_ip
    )

    respond_to do |format|
      format.md do
        @showing_user = user.reload
        @page_title = @showing_user.display_name || @showing_user.name
        @user_tenants = @showing_user.tenant_users.includes(:tenant).map(&:tenant)
        render 'show_user'
      end
      format.html do
        flash[:notice] = "User #{user.display_name} has been unsuspended."
        redirect_to "/app-admin/users/#{user.id}"
      end
    end
  end

  # GET /app-admin/users/:id/actions/toggle_billing_exempt
  def describe_toggle_billing_exempt
    @showing_user = User.find_by(id: params[:id])
    return render(plain: "404 Not Found", status: :not_found) unless @showing_user
    render_action_description(ActionsHelper.action_description("toggle_billing_exempt"))
  end

  # POST /app-admin/users/:id/actions/toggle_billing_exempt
  def execute_toggle_billing_exempt
    user = User.find_by(id: params[:id])
    return render(plain: "404 Not Found", status: :not_found) unless user

    new_value = !user.billing_exempt?
    user.update!(billing_exempt: new_value)

    # Sync billing quantity after exemption change to keep Stripe in sync
    StripeService.sync_subscription_quantity!(user) if user.human?

    action = new_value ? "granted" : "revoked"
    SecurityAuditLog.log_admin_action(
      admin: @current_user,
      ip: request.remote_ip,
      action: "billing_exempt_#{action}",
      target_user_id: user.id,
      details: { user_name: user.display_name },
    )

    respond_to do |format|
      format.md do
        @showing_user = user.reload
        @page_title = @showing_user.display_name || @showing_user.name
        @user_tenants = @showing_user.tenant_users.includes(:tenant).map(&:tenant)
        render "show_user"
      end
      format.html do
        flash[:notice] = "Billing exemption #{action} for #{user.display_name}."
        redirect_to "/app-admin/users/#{user.id}"
      end
    end
  end

  # POST /app-admin/users/:id/actions/account_security_reset
  def execute_account_security_reset
    user = User.find_by(id: params[:id])
    return render(plain: "404 Not Found", status: :not_found) unless user

    # 1. Revoke all sessions and delete API tokens (user + child AI agents)
    user.revoke_all_sessions!

    # 2. Invalidate password and send reset email (if user has a password identity)
    identity = OmniAuthIdentity.find_by(user_id: user.id)
    if identity
      random_password = SecureRandom.hex(32)
      identity.password = random_password
      identity.password_confirmation = random_password
      identity.save!

      raw_token = identity.generate_reset_password_token!
      begin
        PasswordResetMailer.reset_password_instructions(identity, raw_token).deliver_later
      rescue StandardError => e
        Rails.logger.error("Failed to send password reset email during account security reset: #{e.message}")
      end
    end

    SecurityAuditLog.log_admin_action(
      admin: @current_user,
      ip: request.remote_ip,
      action: "account_security_reset",
      target_user_id: user.id,
      details: { email: user.email, had_password_identity: identity.present? },
    )

    flash[:notice] = "Account security reset complete for #{user.display_name || user.name}."
    redirect_to "/app-admin/users/#{user.id}"
  end

  # ============================================================================
  # Reports
  # ============================================================================

  # GET /app-admin/reports
  def reports
    @page_title = "Reports"
    @filter_status = params[:status] || "pending"
    @content_reports = ContentReport.unscoped_for_admin(@current_user)
    @content_reports = @content_reports.where(status: @filter_status) if @filter_status != "all"
    @content_reports = @content_reports.order(created_at: :desc).limit(100).includes(:reporter, :reportable, :reviewed_by)

    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /app-admin/reports/:id
  def show_report
    @content_report = ContentReport.unscoped_for_admin(@current_user).find(params[:id])
    @page_title = "Report ##{@content_report.id[0..7]}"

    respond_to do |format|
      format.html
      format.md
    end
  end

  # POST /app-admin/reports/:id/review
  def execute_review_report
    report = ContentReport.unscoped_for_admin(@current_user).find(params[:id])
    report.review!(
      admin: @current_user,
      status: params[:status],
      notes: params[:admin_notes],
    )

    SecurityAuditLog.log_admin_action(
      admin: @current_user,
      ip: request.remote_ip,
      action: "review_report",
      target_user_id: report.reporter_id,
      details: { report_id: report.id, status: params[:status] },
    )

    flash[:notice] = "Report marked as #{params[:status]}."
    redirect_to "/app-admin/reports/#{report.id}"
  end

  # Security Audit
  # ============================================================================

  # GET /app-admin/security
  def security_dashboard
    @page_title = 'Security Dashboard'

    # Get security events from log (simplified for initial implementation)
    @security_events = []
    if SecurityAuditLogReader.log_exists?
      result = SecurityAuditLogReader.filtered_events(
        since: 24.hours.ago,
        sort_by: "timestamp",
        sort_dir: "desc",
        page: 1,
        per_page: 50
      )
      @security_events = result[:events]
    end

    # Get suspended users
    @suspended_users = User.where.not(suspended_at: nil).order(suspended_at: :desc).limit(50)

    # Get app admins
    @app_admins = User.where(app_admin: true).order(:name)

    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /app-admin/security/events/:line_number
  def security_event
    line_number = params[:line_number].to_i
    @event = SecurityAuditLogReader.event_at_line(line_number)
    return render(plain: "404 Not Found", status: :not_found) unless @event

    @page_title = "Security Event ##{line_number}"
    respond_to do |format|
      format.html
      format.md
    end
  end

  # ============================================================================
  # Markdown API Actions
  # ============================================================================

  def user_actions_index
    @showing_user = User.find_by(id: params[:id])
    return render(plain: "404 Not Found", status: :not_found) unless @showing_user
    @page_title = "Actions | #{@showing_user.display_name}"
    render_actions_index(ActionsHelper.actions_for_route('/app-admin/users/:id'))
  end

  def actions_index_new_tenant
    @page_title = "Actions | New Tenant"
    render_actions_index(ActionsHelper.actions_for_route('/app-admin/tenants/new'))
  end

  def describe_create_tenant
    render_action_description(ActionsHelper.action_description("create_tenant"))
  end

  def execute_create_tenant
    t = Tenant.new
    t.subdomain = params[:subdomain]
    t.name = params[:name]
    t.save!
    t.create_main_collective!(created_by: @current_user)
    tu = t.add_user!(@current_user)
    tu.add_role!('admin')

    respond_to do |format|
      format.md do
        @showing_tenant = t
        @current_user_is_admin_of_showing_tenant = true
        render 'show_tenant'
      end
      format.html { redirect_to "/app-admin/tenants/#{t.subdomain}/complete" }
    end
  end

  private

  def ensure_primary_tenant
    unless @current_tenant&.subdomain == ENV['PRIMARY_SUBDOMAIN']
      render plain: "404 Not Found", status: :not_found
    end
  end

  def ensure_app_admin
    unless @current_user&.app_admin?
      @sidebar_mode = 'none'
      render status: :forbidden, layout: 'application', template: 'app_admin/403_not_app_admin'
    end
  end

  def set_sidebar_mode
    @sidebar_mode = 'app_admin'
  end

  # Override to prevent ApplicationController from trying to constantize "AppAdmin"
  def current_resource_model
    nil
  end

  def current_resource
    nil
  end
end
