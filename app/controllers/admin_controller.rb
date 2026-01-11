# typed: false

require 'sidekiq/api'
class AdminController < ApplicationController
  before_action :ensure_admin_user
  before_action :ensure_subagent_admin_access
  before_action :block_subagent_admin_writes_in_production

  def admin
    @page_title = 'Admin'
    @team = @current_tenant.team
    respond_to do |format|
      format.html
      format.md
    end
  end

  def tenant_settings
    @page_title = 'Admin Settings'
    respond_to do |format|
      format.html
      format.md
    end
  end

  def update_tenant_settings
    @current_tenant.name = params[:name]
    @current_tenant.timezone = params[:timezone]
    ['api_enabled', 'require_login', 'allow_file_uploads'].each do |setting|
      if ['true', 'false', '1', '0'].include?(params[setting])
        @current_tenant.settings[setting] = params[setting] == 'true' || params[setting] == '1'
      end
    end
    # TODO - Home page, About page, Help page, Contact page
    @current_tenant.save!
    redirect_to "/admin"
  end

  def tenants
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @page_title = 'Tenants'
    @tenants = Tenant.all
    respond_to do |format|
      format.html
      format.md
    end
  end

  def new_tenant
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @page_title = 'New Tenant'
    respond_to do |format|
      format.html
      format.md
    end
  end

  def create_tenant
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    t = Tenant.new
    t.subdomain = params[:subdomain]
    t.name = params[:name]
    t.save!
    t.create_main_studio!(created_by: @current_user)
    tu = t.add_user!(@current_user)
    tu.add_role!('admin')
    redirect_to "/admin/tenants/#{t.subdomain}/complete"
  end

  def complete_tenant_creation
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @tenant = Tenant.find_by(subdomain: params[:subdomain])
    @page_title = 'Complete Tenant Creation'
  end

  def show_tenant
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @showing_tenant = Tenant.find_by(subdomain: params[:subdomain])
    @current_user_is_admin_of_showing_tenant = @showing_tenant.is_admin?(@current_user)
    @page_title = @showing_tenant.name
    respond_to do |format|
      format.html
      format.md
    end
  end

  def sidekiq
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @queues = Sidekiq::Queue.all
    @retries = Sidekiq::RetrySet.new
    @scheduled = Sidekiq::ScheduledSet.new
    @dead = Sidekiq::DeadSet.new
    respond_to do |format|
      format.html
      format.md
    end
  end

  def sidekiq_show_queue
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @queue = Sidekiq::Queue.new(params[:name])
    respond_to do |format|
      format.html
      format.md
    end
  end

  def sidekiq_show_job
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @job = find_job(params[:jid])
    respond_to do |format|
      format.html
      format.md
    end
  end

  def sidekiq_retry_job
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    job = find_job(params[:jid])
    if job
      job.retry
      flash[:notice] = 'Job retried'
    else
      flash[:alert] = 'Job not found'
    end
    redirect_to '/admin/sidekiq'
  end

  # Markdown API actions

  def actions_index
    @page_title = "Actions | Admin"
    render_actions_index(ActionsHelper.actions_for_route('/admin'))
  end

  def actions_index_settings
    @page_title = "Actions | Admin Settings"
    render_actions_index(ActionsHelper.actions_for_route('/admin/settings'))
  end

  def describe_update_tenant_settings
    render_action_description({
      action_name: 'update_tenant_settings',
      resource: nil,
      description: 'Update tenant settings',
      params: [
        { name: 'name', type: 'string', description: 'Tenant name' },
        { name: 'timezone', type: 'string', description: 'Tenant timezone (e.g., "America/New_York")' },
        { name: 'api_enabled', type: 'boolean', description: 'Enable API access for the tenant' },
        { name: 'require_login', type: 'boolean', description: 'Require login to view content' },
        { name: 'allow_file_uploads', type: 'boolean', description: 'Allow file uploads' },
      ],
    })
  end

  def execute_update_tenant_settings
    @current_tenant.name = params[:name] if params[:name].present?
    @current_tenant.timezone = params[:timezone] if params[:timezone].present?
    ['api_enabled', 'require_login', 'allow_file_uploads'].each do |setting|
      if ['true', 'false', '1', '0'].include?(params[setting])
        @current_tenant.settings[setting] = params[setting] == 'true' || params[setting] == '1'
      end
    end
    @current_tenant.save!

    respond_to do |format|
      format.md { render 'tenant_settings' }
      format.html { redirect_to "/admin" }
    end
  end

  def actions_index_new_tenant
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @page_title = "Actions | New Tenant"
    render_actions_index(ActionsHelper.actions_for_route('/admin/tenants/new'))
  end

  def describe_create_tenant
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    render_action_description({
      action_name: 'create_tenant',
      resource: nil,
      description: 'Create a new tenant',
      params: [
        { name: 'subdomain', type: 'string', description: 'Unique subdomain for the tenant (used in URL)' },
        { name: 'name', type: 'string', description: 'Display name for the tenant' },
      ],
    })
  end

  def execute_create_tenant
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    t = Tenant.new
    t.subdomain = params[:subdomain]
    t.name = params[:name]
    t.save!
    t.create_main_studio!(created_by: @current_user)
    tu = t.add_user!(@current_user)
    tu.add_role!('admin')

    respond_to do |format|
      format.md do
        @showing_tenant = t
        @current_user_is_admin_of_showing_tenant = true
        render 'show_tenant'
      end
      format.html { redirect_to "/admin/tenants/#{t.subdomain}/complete" }
    end
  end

  def actions_index_sidekiq_job
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @job = find_job(params[:jid])
    @page_title = "Actions | Sidekiq Job"
    render_actions_index(ActionsHelper.actions_for_route('/admin/sidekiq/jobs/:jid'))
  end

  def describe_retry_sidekiq_job
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    @job = find_job(params[:jid])
    return render status: 404, plain: '404 Job not found' if @job.nil?
    render_action_description({
      action_name: 'retry_sidekiq_job',
      resource: nil,
      description: 'Retry this Sidekiq job',
      params: [],
    })
  end

  def execute_retry_sidekiq_job
    return render status: 403, plain: '403 Unauthorized' unless is_main_tenant?
    job = find_job(params[:jid])
    return render status: 404, plain: '404 Job not found' if job.nil?

    if job.respond_to?(:retry)
      job.retry
      respond_to do |format|
        format.md do
          @queues = Sidekiq::Queue.all
          @retries = Sidekiq::RetrySet.new
          @scheduled = Sidekiq::ScheduledSet.new
          @dead = Sidekiq::DeadSet.new
          render 'sidekiq'
        end
        format.html do
          flash[:notice] = 'Job retried'
          redirect_to '/admin/sidekiq'
        end
      end
    else
      respond_to do |format|
        format.md { render plain: 'This job cannot be retried', status: 400 }
        format.html do
          flash[:alert] = 'This job cannot be retried'
          redirect_to '/admin/sidekiq'
        end
      end
    end
  end

  private

  def ensure_admin_user
    unless @current_tenant.is_admin?(@current_user)
      return render status: 403, layout: 'application', html: 'You must be an admin to access this page.'
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

  # Extracted to allow testing with production environment simulation
  # In tests, set Thread.current[:simulate_production] = true to simulate production
  def production_environment?
    return true if Thread.current[:simulate_production]
    Rails.env.production?
  end
  helper_method :can_perform_admin_actions?

  def is_main_tenant?
    @current_tenant.subdomain == ENV['PRIMARY_SUBDOMAIN']
  end

  def current_resource_model
    Tenant
  end

  def current_resource
    @current_tenant
  end

  def find_job(jid)
    jid = jid.to_s
    job = Sidekiq::Workers.new.find { |_, _, work| work["payload"]["jid"].to_s == jid }
    return job if job

    job = Sidekiq::RetrySet.new.find { |job| job.jid.to_s == jid }
    return job if job

    job = Sidekiq::ScheduledSet.new.find { |job| job.jid.to_s == jid }
    return job if job

    job = Sidekiq::DeadSet.new.find { |job| job.jid.to_s == jid }
    return job if job

    Sidekiq::Queue.all.each do |queue|
      job = queue.find { |job| job.jid.to_s == jid }
      return job if job
    end

    nil
  end

end