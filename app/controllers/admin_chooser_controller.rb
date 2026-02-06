# typed: false

# AdminChooserController handles the /admin route.
#
# It redirects users to the appropriate admin page based on their roles:
# - If they have exactly one admin role, redirect them directly
# - If they have multiple admin roles, show a chooser page
# - If they have no admin roles, show access denied
class AdminChooserController < ApplicationController
  def index
    available_admins = []

    # Check for sys_admin (primary tenant only)
    if primary_tenant? && @current_user&.sys_admin?
      available_admins << { path: '/system-admin', label: 'System Admin', icon: 'server', description: 'Sidekiq jobs and system monitoring' }
    end

    # Check for app_admin (primary tenant only)
    if primary_tenant? && @current_user&.app_admin?
      available_admins << { path: '/app-admin', label: 'App Admin', icon: 'organization', description: 'Manage tenants and users across all tenants' }
    end

    # Check for tenant admin (any tenant)
    if @current_tenant&.is_admin?(@current_user)
      available_admins << { path: '/tenant-admin', label: 'Tenant Admin', icon: 'gear', description: "Manage settings and users for #{@current_tenant.name}" }
    end

    case available_admins.length
    when 0
      # No admin access - show 403
      @sidebar_mode = 'none'
      render status: :forbidden, template: 'admin_chooser/403_not_admin'
    when 1
      # Only one option - redirect directly
      redirect_to available_admins.first[:path]
    else
      # Multiple options - show chooser
      @sidebar_mode = 'none'
      @available_admins = available_admins
      @page_title = 'Admin'
      render :chooser
    end
  end

  private

  def primary_tenant?
    @current_tenant&.subdomain == ENV['PRIMARY_SUBDOMAIN']
  end

  # Override to prevent ApplicationController from trying to constantize
  def current_resource_model
    nil
  end

  def current_resource
    nil
  end
end
