require "test_helper"

class SystemAdminControllerTest < ActionDispatch::IntegrationTest
  def setup
    # Create the primary tenant
    @primary_tenant = Tenant.find_by(subdomain: ENV['PRIMARY_SUBDOMAIN']) ||
                      Tenant.create!(subdomain: ENV['PRIMARY_SUBDOMAIN'], name: "Primary Tenant")
    @primary_tenant.create_main_collective!(created_by: create_user(name: "System")) unless @primary_tenant.main_collective

    # Create a non-primary tenant
    @other_tenant = Tenant.create!(subdomain: "other-#{SecureRandom.hex(4)}", name: "Other Tenant")
    @other_tenant.create_main_collective!(created_by: create_user(name: "System")) unless @other_tenant.main_collective

    # Create users
    @sys_admin_user = create_user(name: "Sys Admin User")
    @sys_admin_user.update!(sys_admin: true)

    @non_sys_admin_user = create_user(name: "Non-Sys Admin User")

    @tenant_admin_user = create_user(name: "Tenant Admin User")
  end

  # ============================================================================
  # SECTION 1: Non-Primary Tenants Cannot Access System Admin
  # ============================================================================

  test "system admin routes return 404 from non-primary tenant" do
    @other_tenant.add_user!(@sys_admin_user)
    tu = @other_tenant.tenant_users.find_by(user: @sys_admin_user)
    tu.add_role!('admin')

    host! "#{@other_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@sys_admin_user, tenant: @other_tenant)

    get "/system-admin"
    assert_response :not_found

    get "/system-admin/sidekiq"
    assert_response :not_found
  end

  # ============================================================================
  # SECTION 2: Non-Sys-Admin Users Cannot Access System Admin
  # ============================================================================

  test "non-sys-admin user cannot access /system-admin dashboard" do
    @primary_tenant.add_user!(@non_sys_admin_user)
    tu = @primary_tenant.tenant_users.find_by(user: @non_sys_admin_user)
    tu.add_role!('admin') # Tenant admin but not sys_admin

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_sys_admin_user, tenant: @primary_tenant)

    get "/system-admin"
    assert_response :forbidden
    assert_match(/Access Denied|system admin/i, response.body)
  end

  test "non-sys-admin user cannot access /system-admin/sidekiq" do
    @primary_tenant.add_user!(@non_sys_admin_user)
    tu = @primary_tenant.tenant_users.find_by(user: @non_sys_admin_user)
    tu.add_role!('admin')

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq"
    assert_response :forbidden
  end

  test "non-sys-admin user cannot access sidekiq queue page" do
    @primary_tenant.add_user!(@non_sys_admin_user)
    tu = @primary_tenant.tenant_users.find_by(user: @non_sys_admin_user)
    tu.add_role!('admin')

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq/queues/default"
    assert_response :forbidden
  end

  # ============================================================================
  # SECTION 3: Sys-Admin Users Can Access System Admin on Primary Tenant
  # ============================================================================

  test "sys-admin user can access /system-admin dashboard" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin"
    assert_response :success
    assert_match(/System Admin/i, response.body)
  end

  test "sys-admin user can access /system-admin/sidekiq" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq"
    assert_response :success
    assert_match(/Sidekiq/i, response.body)
  end

  test "sys-admin user can access sidekiq queue page" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq/queues/default"
    assert_response :success
    assert_match(/Queue:/i, response.body)
  end

  # ============================================================================
  # SECTION 4: Markdown API Responses
  # ============================================================================

  test "sys-admin user can access dashboard as markdown" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/# System Admin/, response.body)
  end

  test "dashboard loads system monitoring data" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin"
    assert_response :success

    # Verify monitoring sections are present
    assert_match(/System Monitoring/, response.body)
    assert_match(/Security/, response.body)
    assert_match(/AI Agents/, response.body)
    assert_match(/Webhooks/, response.body)
    assert_match(/Events/, response.body)
    assert_match(/Resources/, response.body)
  end

  test "dashboard markdown includes monitoring data" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin", headers: { "Accept" => "text/markdown" }
    assert_response :success

    # Verify monitoring sections are present in markdown
    assert_match(/System Monitoring/, response.body)
    assert_match(/Security \(Last 24 hours\)/, response.body)
    assert_match(/AI Agent Task Runs/, response.body)
    assert_match(/Webhook Deliveries/, response.body)
    assert_match(/Event Activity/, response.body)
    assert_match(/System Resources/, response.body)
  end

  test "sys-admin user can access sidekiq as markdown" do
    @primary_tenant.add_user!(@sys_admin_user)

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/sidekiq", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/# Sidekiq Dashboard/, response.body)
  end

  # ============================================================================
  # SECTION 5: sys_admin Role is Global (Not Tenant-Specific)
  # ============================================================================

  test "sys_admin role is stored on User model not TenantUser" do
    user = create_user(name: "New User")
    assert_not user.sys_admin?

    user.update!(sys_admin: true)
    assert user.sys_admin?

    # The role persists regardless of tenant context
    @primary_tenant.add_user!(user)
    @other_tenant.add_user!(user)

    # User should have sys_admin role in both tenants
    assert user.sys_admin?
    assert user.reload.sys_admin?
  end

  # ============================================================================
  # SECTION 5: Agent Runner Task Run Detail
  # ============================================================================

  test "sys_admin can view task run detail page" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    # Create a task run to view — need tenant/collective context for agent creation callbacks
    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Test Agent", email: "agent-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    task_run = AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "Test task for admin view",
      max_steps: 10,
      status: "failed",
      error: "LLM error: connection timeout",
      steps_data: [{ "type" => "error", "timestamp" => Time.current.iso8601, "detail" => { "message" => "LLM error" } }],
      steps_count: 1,
      completed_at: Time.current,
    )

    get system_admin_task_run_path(task_run.id)
    assert_response :success

    # Structural info is visible
    assert_match "Privacy note", response.body
    assert_match "LLM error", response.body
    assert_match task_run.id[0..7], response.body
    assert_match "ERROR", response.body  # step type is shown

    # Tenant content is redacted
    assert_no_match(/Test task for admin view/, response.body, "Task prompt should be redacted")
  end

  test "task run detail page redacts tenant content" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Redact Agent", email: "redact-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    task_run = AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "SENSITIVE_TASK_PROMPT",
      max_steps: 10,
      status: "completed",
      success: true,
      final_message: "SENSITIVE_FINAL_MESSAGE",
      steps_data: [
        { "type" => "navigate", "timestamp" => Time.current.iso8601,
          "detail" => { "path" => "/collectives/test", "content_preview" => "SENSITIVE_PAGE_CONTENT" } },
        { "type" => "think", "timestamp" => Time.current.iso8601,
          "detail" => { "step_number" => 0, "prompt_preview" => "SENSITIVE_PROMPT", "response_preview" => "SENSITIVE_LLM_RESPONSE" } },
        { "type" => "execute", "timestamp" => Time.current.iso8601,
          "detail" => { "action" => "create_note", "params" => { "text" => "SENSITIVE_PARAMS" }, "success" => true, "content_preview" => "SENSITIVE_RESULT" } },
        { "type" => "done", "timestamp" => Time.current.iso8601,
          "detail" => { "message" => "SENSITIVE_DONE_MESSAGE" } },
        { "type" => "scratchpad_update", "timestamp" => Time.current.iso8601,
          "detail" => { "content" => "SENSITIVE_SCRATCHPAD" } },
      ],
      steps_count: 5,
      completed_at: Time.current,
    )

    get system_admin_task_run_path(task_run.id)
    assert_response :success

    # Structural info is visible
    assert_match "create_note", response.body
    assert_match "/collectives/test", response.body
    assert_match "NAVIGATE", response.body

    # Tenant content is redacted
    assert_no_match(/SENSITIVE_TASK_PROMPT/, response.body)
    assert_no_match(/SENSITIVE_FINAL_MESSAGE/, response.body)
    assert_no_match(/SENSITIVE_PAGE_CONTENT/, response.body)
    assert_no_match(/SENSITIVE_PROMPT/, response.body)
    assert_no_match(/SENSITIVE_LLM_RESPONSE/, response.body)
    assert_no_match(/SENSITIVE_PARAMS/, response.body)
    assert_no_match(/SENSITIVE_RESULT/, response.body)
    assert_no_match(/SENSITIVE_DONE_MESSAGE/, response.body)
    assert_no_match(/SENSITIVE_SCRATCHPAD/, response.body)
  end

  test "sys_admin can filter task runs by status" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/agent-runner?status=failed"
    assert_response :success
  end

  test "non-sys-admin cannot view task run detail" do
    @primary_tenant.add_user!(@non_sys_admin_user)
    tu = @primary_tenant.tenant_users.find_by(user: @non_sys_admin_user)
    tu.add_role!('admin')

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_sys_admin_user, tenant: @primary_tenant)

    get "/system-admin/agent-runner/runs/#{SecureRandom.uuid}"
    assert_response :forbidden
  end
end
