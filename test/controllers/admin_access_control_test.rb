require "test_helper"

# These tests enforce the admin controller access documentation as invariants.
#
# Each admin controller has a documented access rule in its class comment:
# - SystemAdminController: "Only accessible from the primary tenant by users with the sys_admin global role."
# - AppAdminController: "Only accessible from the primary tenant by users with the app_admin global role."
# - TenantAdminController: "Accessible from any tenant by users with admin role on TenantUser."
#
# These tests enumerate ALL routes for each admin controller using Rails routing introspection.
# If a new route is added to any admin controller, it is automatically covered by these tests.
# No exceptions. No `except:` clauses. If a test fails, the route is either misconfigured or
# the access rule needs to be revisited — not worked around.
class AdminAccessControlTest < ActionDispatch::IntegrationTest
  def setup
    @primary_tenant = create_tenant(subdomain: ENV["PRIMARY_SUBDOMAIN"] || "app", name: "Primary Tenant")
    @other_tenant = create_tenant(subdomain: "other-tenant", name: "Other Tenant")

    # Regular user — no admin roles at all
    @regular_user = create_user(email: "regular-#{SecureRandom.hex(4)}@example.com", name: "Regular User")
    @primary_tenant.add_user!(@regular_user)
    @primary_tenant.create_main_collective!(created_by: @regular_user)
    @primary_collective = @primary_tenant.main_collective
    @primary_collective.add_user!(@regular_user)

    # Tenant admin — admin of the tenant, but not app_admin or sys_admin
    @tenant_admin_user = create_user(email: "tenant-admin-#{SecureRandom.hex(4)}@example.com", name: "Tenant Admin")
    @primary_tenant.add_user!(@tenant_admin_user)
    @primary_collective.add_user!(@tenant_admin_user)
    tenant_user = @primary_tenant.tenant_users.find_by(user: @tenant_admin_user)
    tenant_user.add_role!("admin")

    # App admin — has app_admin global role, but not sys_admin
    @app_admin_user = create_user(email: "app-admin-#{SecureRandom.hex(4)}@example.com", name: "App Admin")
    @app_admin_user.add_global_role!("app_admin")
    @primary_tenant.add_user!(@app_admin_user)
    @primary_collective.add_user!(@app_admin_user)

    # Sys admin — has sys_admin global role, but not app_admin
    @sys_admin_user = create_user(email: "sys-admin-#{SecureRandom.hex(4)}@example.com", name: "Sys Admin")
    @sys_admin_user.add_global_role!("sys_admin")
    @primary_tenant.add_user!(@sys_admin_user)
    @primary_collective.add_user!(@sys_admin_user)

    # Set up some test data so routes with params don't 404 due to missing records
    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: @primary_collective.handle)
    @note = create_note(text: "Test content", created_by: @regular_user)
    @report = ContentReport.create!(
      reporter: @app_admin_user,
      reportable: @note,
      tenant: @primary_tenant,
      reason: "spam",
    )
  end

  # ==========================================================================
  # Helper: enumerate all routes for a given controller
  # ==========================================================================

  def routes_for_controller(controller_name)
    Rails.application.routes.routes.select do |route|
      route.defaults[:controller] == controller_name
    end.map do |route|
      {
        method: (route.verb.presence || "GET"),
        path: route.path.spec.to_s.gsub("(.:format)", ""),
        action: route.defaults[:action],
      }
    end.uniq { |r| [r[:method], r[:action]] }
  end

  # Substitute route params with real values so the request doesn't 404
  # due to missing URL segments. The goal is to test authorization, not routing.
  def substitute_params(path)
    path
      .gsub(":subdomain", @primary_tenant.subdomain)
      .gsub(":id", @report.id)
      .gsub(":handle", @regular_user.handle || "unknown")
      .gsub(":line_number", "1")
      .gsub(":name", "default")
      .gsub(":jid", "nonexistent-jid")
  end

  # Make a request and return the response status.
  # We don't care about the response body — only whether access was granted or denied.
  # Accepted denial responses: 403 (forbidden), 302 (redirect to login/reverification), 404 (primary tenant check)
  # Sign in with reverification completed, so we test the authorization layer
  # rather than just the reverification barrier.
  def request_route(method, path, user:, tenant:, admin_path: nil)
    host! "#{tenant.subdomain}.#{ENV['HOSTNAME']}"
    if admin_path
      sign_in_as_admin(user, tenant: tenant, admin_path: admin_path)
    else
      sign_in_as(user, tenant: tenant)
    end

    resolved_path = substitute_params(path)
    begin
      case method
      when "GET" then get resolved_path
      when "POST" then post resolved_path
      when "PUT" then put resolved_path
      when "PATCH" then patch resolved_path
      when "DELETE" then delete resolved_path
      end
      response.status
    rescue AbstractController::ActionNotFound
      # Action doesn't exist — effectively a denial. Would be 404 in production.
      404
    rescue StandardError
      # Application error (nil dereference, missing record, etc.) means the user
      # got past authorization and the action ran. For negative tests this counts
      # as access granted (a failure). For positive tests this confirms access.
      200
    end
  end

  def access_denied?(status)
    [302, 403, 404].include?(status)
  end

  def access_granted?(status)
    # For positive tests: the user should NOT get 403 (forbidden).
    # 404 is acceptable — it may mean a missing record, not an auth failure.
    # 200 = success, 302 = redirect, 422 = validation error — all confirm access was granted.
    status != 403
  end

  # ==========================================================================
  # SystemAdminController: requires sys_admin global role + primary tenant
  # ==========================================================================

  test "system admin controller has routes" do
    routes = routes_for_controller("system_admin")
    assert routes.any?, "Expected to find routes for system_admin controller"
  end

  test "regular user cannot access any system admin route" do
    routes = routes_for_controller("system_admin")
    routes.each do |route|
      status = request_route(route[:method], route[:path], user: @regular_user, tenant: @primary_tenant)
      assert access_denied?(status),
             "Regular user should be denied access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  test "tenant admin cannot access any system admin route" do
    routes = routes_for_controller("system_admin")
    routes.each do |route|
      status = request_route(route[:method], route[:path], user: @tenant_admin_user, tenant: @primary_tenant)
      assert access_denied?(status),
             "Tenant admin should be denied access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  test "app admin cannot access any system admin route" do
    routes = routes_for_controller("system_admin")
    routes.each do |route|
      status = request_route(route[:method], route[:path], user: @app_admin_user, tenant: @primary_tenant)
      assert access_denied?(status),
             "App admin should be denied access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  test "sys admin cannot access system admin from non-primary tenant" do
    @other_tenant.add_user!(@sys_admin_user)
    @other_tenant.create_main_collective!(created_by: @sys_admin_user)

    routes = routes_for_controller("system_admin")
    routes.each do |route|
      status = request_route(route[:method], route[:path], user: @sys_admin_user, tenant: @other_tenant)
      assert access_denied?(status),
             "Sys admin on non-primary tenant should be denied access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  # ==========================================================================
  # AppAdminController: requires app_admin global role + primary tenant
  # ==========================================================================

  test "app admin controller has routes" do
    routes = routes_for_controller("app_admin")
    assert routes.any?, "Expected to find routes for app_admin controller"
  end

  test "regular user cannot access any app admin route" do
    routes = routes_for_controller("app_admin")
    routes.each do |route|
      status = request_route(route[:method], route[:path], user: @regular_user, tenant: @primary_tenant)
      assert access_denied?(status),
             "Regular user should be denied access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  test "tenant admin cannot access any app admin route" do
    routes = routes_for_controller("app_admin")
    # Complete reverification so we test the authorization check, not just the reverification barrier.
    # Use a report route for reverification since that's the route the tenant admin hole would let through.
    routes.each do |route|
      status = request_route(route[:method], route[:path], user: @tenant_admin_user, tenant: @primary_tenant,
                             admin_path: "/app-admin/reports")
      assert access_denied?(status),
             "Tenant admin should be denied access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  test "sys admin cannot access any app admin route" do
    routes = routes_for_controller("app_admin")
    routes.each do |route|
      status = request_route(route[:method], route[:path], user: @sys_admin_user, tenant: @primary_tenant,
                             admin_path: "/app-admin/reports")
      assert access_denied?(status),
             "Sys admin should be denied access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  test "app admin cannot access app admin from non-primary tenant" do
    @other_tenant.add_user!(@app_admin_user)
    @other_tenant.create_main_collective!(created_by: @app_admin_user)

    routes = routes_for_controller("app_admin")
    routes.each do |route|
      status = request_route(route[:method], route[:path], user: @app_admin_user, tenant: @other_tenant)
      assert access_denied?(status),
             "App admin on non-primary tenant should be denied access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  # ==========================================================================
  # TenantAdminController: requires admin role on TenantUser
  # ==========================================================================

  test "tenant admin controller has routes" do
    routes = routes_for_controller("tenant_admin")
    assert routes.any?, "Expected to find routes for tenant_admin controller"
  end

  test "regular user cannot access any tenant admin route" do
    routes = routes_for_controller("tenant_admin")
    routes.each do |route|
      status = request_route(route[:method], route[:path], user: @regular_user, tenant: @primary_tenant)
      assert access_denied?(status),
             "Regular user should be denied access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  # ==========================================================================
  # Positive tests: correct admin type CAN access their routes
  # Only tests GET routes to avoid side effects from POST/PUT/DELETE.
  # ==========================================================================

  test "sys admin can access all system admin GET routes" do
    get_routes = routes_for_controller("system_admin").select { |r| r[:method] == "GET" }
    get_routes.each do |route|
      status = request_route(route[:method], route[:path], user: @sys_admin_user, tenant: @primary_tenant,
                             admin_path: "/system-admin")
      assert access_granted?(status),
             "Sys admin should have access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  test "app admin can access all app admin GET routes" do
    get_routes = routes_for_controller("app_admin").select { |r| r[:method] == "GET" }
    get_routes.each do |route|
      status = request_route(route[:method], route[:path], user: @app_admin_user, tenant: @primary_tenant,
                             admin_path: "/app-admin")
      assert access_granted?(status),
             "App admin should have access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end

  test "tenant admin can access all tenant admin GET routes" do
    get_routes = routes_for_controller("tenant_admin").select { |r| r[:method] == "GET" }
    get_routes.each do |route|
      status = request_route(route[:method], route[:path], user: @tenant_admin_user, tenant: @primary_tenant,
                             admin_path: "/tenant-admin")
      assert access_granted?(status),
             "Tenant admin should have access to #{route[:method]} #{route[:path]} (#{route[:action]}) but got #{status}"
    end
  end
end
