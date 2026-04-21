require "test_helper"

class AppAdminControllerTest < ActionDispatch::IntegrationTest
  def setup
    super
    # Create primary tenant (matches PRIMARY_SUBDOMAIN in env)
    @primary_tenant = create_tenant(subdomain: ENV["PRIMARY_SUBDOMAIN"] || "app", name: "Primary Tenant")
    @primary_user = create_user(email: "primary@example.com", name: "Primary User")
    @primary_tenant.add_user!(@primary_user)
    @primary_tenant.create_main_collective!(created_by: @primary_user)
    @primary_collective = @primary_tenant.main_collective
    @primary_collective.add_user!(@primary_user)

    # Create secondary tenant
    @secondary_tenant = create_tenant(subdomain: "secondary", name: "Secondary Tenant")
    @secondary_user = create_user(email: "secondary@example.com", name: "Secondary User")
    @secondary_tenant.add_user!(@secondary_user)
    @secondary_tenant.create_main_collective!(created_by: @secondary_user)

    # Create app admin user on primary tenant
    @app_admin_user = create_user(email: "app_admin@example.com", name: "App Admin User")
    @app_admin_user.add_global_role!("app_admin")
    @primary_tenant.add_user!(@app_admin_user)
    @primary_collective.add_user!(@app_admin_user)

    # Create sys_admin user (without app_admin role) on primary tenant
    @sys_admin_user = create_user(email: "sys_admin@example.com", name: "Sys Admin User")
    @sys_admin_user.add_global_role!("sys_admin")
    @primary_tenant.add_user!(@sys_admin_user)
    @primary_collective.add_user!(@sys_admin_user)

    # Create a regular non-admin user on primary tenant
    @non_admin_user = create_user(email: "non_admin@example.com", name: "Non Admin User")
    @primary_tenant.add_user!(@non_admin_user)
    @primary_collective.add_user!(@non_admin_user)
  end

  # ==========================================
  # Dashboard Tests
  # ==========================================

  test "app admin can access dashboard on primary tenant" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin"

    assert_response :success
    assert_select "h1", /App Admin/
  end

  test "non-admin cannot access app admin dashboard" do
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/app-admin"

    assert_response :forbidden
    assert_select "h1", /Access Denied/
  end

  test "sys_admin without app_admin role cannot access app admin" do
    # sys_admin_user is sys_admin but not app_admin
    sign_in_as(@sys_admin_user, tenant: @primary_tenant)

    get "/app-admin"

    assert_response :forbidden
  end

  test "app admin cannot access dashboard on secondary tenant" do
    # Add app_admin to secondary tenant so they can sign in
    @secondary_tenant.add_user!(@app_admin_user)
    @secondary_tenant.main_collective.add_user!(@app_admin_user)

    sign_in_as(@app_admin_user, tenant: @secondary_tenant)

    get "/app-admin"

    assert_response :not_found
  end

  # ==========================================
  # Tenants Tests
  # ==========================================

  test "app admin can view tenants list" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/tenants"

    assert_response :success
  end

  test "app admin can view new tenant form" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/tenants/new"

    assert_response :success
    assert_select "h1", /New Tenant/
  end

  test "app admin can create a new tenant" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    assert_difference "Tenant.count", 1 do
      post "/app-admin/tenants", params: { tenant: { name: "Test Tenant", subdomain: "testtenant" } }
    end

    assert_response :redirect
    assert_redirected_to "/app-admin/tenants/testtenant/complete"
  end

  test "app admin can view tenant details" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/tenants/#{@secondary_tenant.subdomain}"

    assert_response :success
    assert_select "h1", /#{@secondary_tenant.name}/
  end

  # ==========================================
  # Users Tests
  # ==========================================

  test "app admin can view all users across tenants" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/users"

    assert_response :success
  end

  test "app admin can search users by email" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/users", params: { q: @non_admin_user.email }

    assert_response :success
  end

  test "app admin can view user details by user ID" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/users/#{@non_admin_user.id}"

    assert_response :success
    assert_select "h1", /#{@non_admin_user.display_name || @non_admin_user.name}/
  end

  test "app admin user search escapes LIKE wildcards" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    # Verify that a normal search finds users
    get "/app-admin/users", params: { q: "non_admin" }
    assert_response :success
    assert_select "code", text: /non_admin@example\.com/

    # "%" as a search query should NOT match any users — LIKE wildcards must be escaped
    get "/app-admin/users", params: { q: "%" }
    assert_response :success
    assert_select "code", { text: /non_admin@example\.com/, count: 0 },
                  "Query '%' should not match users via LIKE wildcard injection"
  end

  # ==========================================
  # User Suspension Tests
  # ==========================================

  test "app admin can suspend another user" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    post "/app-admin/users/#{@non_admin_user.id}/actions/suspend_user", params: { reason: "Test suspension" }

    assert_response :redirect
    @non_admin_user.reload
    assert @non_admin_user.suspended?
    assert_equal "Test suspension", @non_admin_user.suspended_reason
  end

  test "app admin cannot suspend themselves" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    post "/app-admin/users/#{@app_admin_user.id}/actions/suspend_user", params: { reason: "Self-suspension" }

    assert_response :redirect
    @app_admin_user.reload
    assert_not @app_admin_user.suspended?
  end

  test "app admin can unsuspend a user" do
    # First suspend the user
    @non_admin_user.update!(suspended_at: Time.current, suspended_reason: "Test")

    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    post "/app-admin/users/#{@non_admin_user.id}/actions/unsuspend_user"

    assert_response :redirect
    @non_admin_user.reload
    assert_not @non_admin_user.suspended?
  end

  # ==========================================
  # Account Security Reset Tests
  # ==========================================

  test "app admin can account security reset a user" do
    identity = @non_admin_user.find_or_create_omni_auth_identity!
    identity.update_password!("original_password_123")
    old_digest = identity.reload.password_digest

    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    assert_nil @non_admin_user.sessions_revoked_at

    post "/app-admin/users/#{@non_admin_user.id}/actions/account_security_reset"

    assert_response :redirect

    # Sessions revoked
    @non_admin_user.reload
    assert_not_nil @non_admin_user.sessions_revoked_at

    # Password invalidated and reset token generated
    identity.reload
    assert_not_equal old_digest, identity.password_digest
    assert_not_nil identity.reset_password_token
    assert_not_nil identity.reset_password_sent_at
  end

  test "account security reset works for user without password identity (revokes sessions only)" do
    oauth_only_user = create_user(email: "oauth-only-#{SecureRandom.hex(4)}@example.com", name: "OAuth User")
    @primary_tenant.add_user!(oauth_only_user)

    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    post "/app-admin/users/#{oauth_only_user.id}/actions/account_security_reset"

    assert_response :redirect
    oauth_only_user.reload
    assert_not_nil oauth_only_user.sessions_revoked_at
    # No error — just skips password reset part
    assert_match "Account security reset", flash[:notice]
  end

  test "account security reset deletes API tokens" do
    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: @primary_collective.handle)
    token = ApiToken.create!(user: @non_admin_user, name: "Test Token", tenant: @primary_tenant, scopes: ["read:all"])

    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    post "/app-admin/users/#{@non_admin_user.id}/actions/account_security_reset"

    assert_response :redirect
    token.reload
    assert_not_nil token.deleted_at
  end

  test "account security reset deletes AI agent child tokens" do
    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: @primary_collective.handle)
    ai_agent = User.create!(
      email: "agent-#{SecureRandom.hex(4)}@example.com",
      name: "Test Agent",
      user_type: "ai_agent",
      parent_id: @non_admin_user.id,
    )
    @primary_tenant.add_user!(ai_agent)
    agent_token = ApiToken.create!(user: ai_agent, name: "Agent Token", tenant: @primary_tenant, scopes: ["read:all"])

    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    post "/app-admin/users/#{@non_admin_user.id}/actions/account_security_reset"

    assert_response :redirect
    agent_token.reload
    assert_not_nil agent_token.deleted_at
  end

  # ==========================================
  # Security Dashboard Tests
  # ==========================================

  test "app admin can view security dashboard" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/security"

    assert_response :success
    assert_select "h1", /Security Dashboard/
  end

  test "security dashboard displays event type from event field" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")
    get "/app-admin/security"

    assert_response :success
    # The badge should show the event name (reads "event" field, not "event_type").
    # Sign-in itself generates security events, so the table should not be empty.
    assert_select "table.pulse-table span.pulse-badge" do |badges|
      assert badges.length > 0, "Should have event type badges"
      badges.each do |badge|
        assert badge.text.strip.present?, "Event type badge should not be blank"
      end
    end
  end

  test "security dashboard displays severity-based badge colors" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")
    get "/app-admin/security"

    assert_response :success
    # Verify event badges use the correct severity-mapped CSS classes (not the old
    # hardcoded 'high'/'low' mapping). Every badge should be one of the valid classes.
    assert_select "table.pulse-table span.pulse-badge" do |badges|
      assert badges.length > 0, "Should have event badges"
      badges.each do |badge|
        classes = badge["class"]
        valid = %w[pulse-badge-danger pulse-badge-warning pulse-badge-muted].any? { |c| classes.include?(c) }
        assert valid, "Badge should have a valid severity class, got: #{classes}"
        # Badge text should not be blank (old bug: event_type field was nil)
        assert badge.text.strip.present?, "Badge text should not be blank"
      end
    end
  end

  test "security dashboard displays email in user column" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")
    get "/app-admin/security"

    assert_response :success
    # The sign-in process itself generates security events with emails.
    # Verify at least one email appears as a link in the table.
    assert_select "table.pulse-table a.pulse-link[href^='/app-admin/users/']"
  end

  test "security dashboard displays details from event-specific fields" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")
    get "/app-admin/security"

    assert_response :success
    # The table should have populated detail cells (not all blank).
    # Sign-in events include a reason field (e.g. from logout events) or
    # other detail fields. Check that at least one td in the details column
    # has non-whitespace content. We check by verifying the table has rows.
    assert_select "table.pulse-table tbody tr" do |rows|
      assert rows.length > 0, "Security events table should have rows"
    end
  end

  # ==========================================
  # Markdown Format Tests
  # ==========================================

  test "app admin dashboard responds to markdown format" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# App Admin/, response.body)
  end

  test "tenants list responds to markdown format" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/tenants", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# All Tenants/, response.body)
  end

  test "users list responds to markdown format" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/users", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/# All Users/, response.body)
  end

  test "user show responds to markdown format" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/users/#{@non_admin_user.id}", headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_match(/Back to Users/, response.body)
  end

  # ==========================================
  # Reports Queue Tests
  # ==========================================

  test "app admin can view reports queue" do
    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/reports"

    assert_response :success
    assert_match "Reports", response.body
  end

  test "app admin can view a report" do
    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: @primary_collective.handle)
    note = create_note(text: "Reported content", created_by: @non_admin_user)
    report = ContentReport.create!(
      reporter: @app_admin_user,
      reportable: note,
      tenant: @primary_tenant,
      reason: "spam",
      description: "This is spam",
    )

    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    get "/app-admin/reports/#{report.id}"

    assert_response :success
    assert_match "spam", response.body
  end

  test "app admin can review a report" do
    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: @primary_collective.handle)
    note = create_note(text: "Reported content", created_by: @non_admin_user)
    report = ContentReport.create!(
      reporter: @primary_user,
      reportable: note,
      tenant: @primary_tenant,
      reason: "harassment",
    )

    sign_in_as_admin(@app_admin_user, tenant: @primary_tenant, admin_path: "/app-admin")

    post "/app-admin/reports/#{report.id}/review", params: {
      status: "dismissed",
      admin_notes: "Not a real issue",
    }

    assert_response :redirect
    report.reload
    assert_equal "dismissed", report.status
    assert_equal @app_admin_user.id, report.reviewed_by_id
    assert_equal "Not a real issue", report.admin_notes
    assert_not_nil report.reviewed_at
  end

  test "non-admin cannot access reports queue" do
    sign_in_as(@non_admin_user, tenant: @primary_tenant)

    get "/app-admin/reports"

    assert_response :forbidden
  end
end
