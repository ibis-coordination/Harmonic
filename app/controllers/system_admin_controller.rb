# typed: false

require 'sidekiq/api'

# SystemAdminController handles system-level administration.
#
# Access: Only accessible from the primary tenant by users with the sys_admin global role.
#
# Features:
# - Sidekiq queue management (view queues, jobs, retry failed jobs)
# - Future: System monitoring metrics, health checks
#
# This is distinct from:
# - AppAdminController: Manages tenants and users across all tenants
# - TenantAdminController: Manages a single tenant's settings and users
class SystemAdminController < ApplicationController
  layout 'pulse'
  before_action :ensure_primary_tenant
  before_action :ensure_sys_admin
  before_action :set_sidebar_mode

  # GET /system-admin
  def dashboard
    @page_title = 'System Admin'
    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /system-admin/sidekiq
  def sidekiq
    @page_title = 'Sidekiq'
    @queues = Sidekiq::Queue.all
    @retries = Sidekiq::RetrySet.new
    @scheduled = Sidekiq::ScheduledSet.new
    @dead = Sidekiq::DeadSet.new
    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /system-admin/sidekiq/queues/:name
  def sidekiq_show_queue
    @page_title = "Queue: #{params[:name]}"
    @queue = Sidekiq::Queue.new(params[:name])
    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /system-admin/sidekiq/jobs/:jid
  def sidekiq_show_job
    @job = find_job(params[:jid])
    return render("shared/404", status: :not_found) unless @job
    @page_title = "Job: #{params[:jid][0..7]}..."
    respond_to do |format|
      format.html
      format.md
    end
  end

  # POST /system-admin/sidekiq/jobs/:jid/retry
  def sidekiq_retry_job
    job = find_job(params[:jid])
    if job && job.respond_to?(:retry)
      job.retry
      flash[:notice] = 'Job retried'
    else
      flash[:alert] = 'Job not found or cannot be retried'
    end
    redirect_to '/system-admin/sidekiq'
  end

  # Markdown API actions

  # GET /system-admin/sidekiq/jobs/:jid/actions
  def sidekiq_job_actions_index
    @job = find_job(params[:jid])
    return render("shared/404", status: :not_found) unless @job
    @page_title = "Actions | Sidekiq Job"
    render_actions_index(ActionsHelper.actions_for_route('/system-admin/sidekiq/jobs/:jid'))
  end

  # GET /system-admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job
  def describe_retry_sidekiq_job
    @job = find_job(params[:jid])
    return render("shared/404", status: :not_found) unless @job
    render_action_description(ActionsHelper.action_description("retry_sidekiq_job"))
  end

  # POST /system-admin/sidekiq/jobs/:jid/actions/retry_sidekiq_job
  def execute_retry_sidekiq_job
    job = find_job(params[:jid])
    return render("shared/404", status: :not_found) unless job

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
          redirect_to '/system-admin/sidekiq'
        end
      end
    else
      respond_to do |format|
        format.md { render plain: 'This job cannot be retried', status: 400 }
        format.html do
          flash[:alert] = 'This job cannot be retried'
          redirect_to '/system-admin/sidekiq'
        end
      end
    end
  end

  private

  def ensure_primary_tenant
    unless @current_tenant&.subdomain == ENV['PRIMARY_SUBDOMAIN']
      render plain: "404 Not Found", status: :not_found
    end
  end

  def ensure_sys_admin
    unless @current_user&.sys_admin?
      @sidebar_mode = 'none'
      render status: :forbidden, layout: 'pulse', template: 'system_admin/403_not_sys_admin'
    end
  end

  def set_sidebar_mode
    @sidebar_mode = 'system_admin'
  end

  def find_job(jid)
    jid = jid.to_s
    job = Sidekiq::Workers.new.find { |_, _, work| work["payload"]["jid"].to_s == jid }
    return job if job

    job = Sidekiq::RetrySet.new.find { |j| j.jid.to_s == jid }
    return job if job

    job = Sidekiq::ScheduledSet.new.find { |j| j.jid.to_s == jid }
    return job if job

    job = Sidekiq::DeadSet.new.find { |j| j.jid.to_s == jid }
    return job if job

    Sidekiq::Queue.all.each do |queue|
      job = queue.find { |j| j.jid.to_s == jid }
      return job if job
    end

    nil
  end

  # Override to prevent ApplicationController from trying to constantize "SystemAdmin"
  def current_resource_model
    nil
  end

  def current_resource
    nil
  end
end
