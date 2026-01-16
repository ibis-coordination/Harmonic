# typed: false

# HasGlobalRoles provides app-wide roles that are NOT scoped to any tenant or superagent.
#
# This is distinct from HasRoles (used by TenantUser and SuperagentMember), which provides
# roles scoped to a specific tenant or superagent (e.g., "admin" within a tenant).
#
# Global roles apply across the entire application. Currently supported:
#
# - `app_admin`: Grants access to the Admin API (/api/app_admin/*) for managing all tenants.
#   This is used by the Harmonic Admin App (private repo) for billing, support, and operations.
#
# - `sys_admin`: Reserved for future system-level administrative access.
#
# These roles are stored as boolean columns on the User model (app_admin, sys_admin)
# and are set via Rails console only.
#
# The redundant check (both token flag AND user role) is a security feature - see ADMIN_API_PLAN.md.
#
# Example usage (via Rails console):
#   user = User.find_by(email: "admin@example.com")
#   user.update!(app_admin: true)
#   user.app_admin?  # => true
#
module HasGlobalRoles
  extend ActiveSupport::Concern

  # Returns true if user has the app_admin global role.
  # App admins can access /api/app_admin/* endpoints (when combined with an app_admin token).
  def app_admin?
    app_admin == true
  end

  # Returns true if user has the sys_admin global role.
  def sys_admin?
    sys_admin == true
  end

  # Convenience method to grant a global role.
  def add_global_role!(role)
    case role
    when "app_admin"
      update!(app_admin: true)
    when "sys_admin"
      update!(sys_admin: true)
    else
      raise "Invalid global role: #{role}. Valid roles: app_admin, sys_admin"
    end
  end

  # Convenience method to revoke a global role.
  def remove_global_role!(role)
    case role
    when "app_admin"
      update!(app_admin: false)
    when "sys_admin"
      update!(sys_admin: false)
    else
      raise "Invalid global role: #{role}. Valid roles: app_admin, sys_admin"
    end
  end
end
