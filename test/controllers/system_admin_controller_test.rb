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
      steps_count: 1,
      completed_at: Time.current,
    )
    task_run.agent_session_steps.create!(position: 0, step_type: "error", detail: { "message" => "LLM error" })

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
      steps_count: 5,
      completed_at: Time.current,
    )
    task_run.agent_session_steps.create!(position: 0, step_type: "navigate",
      detail: { "path" => "/collectives/test", "content_preview" => "SENSITIVE_PAGE_CONTENT" })
    task_run.agent_session_steps.create!(position: 1, step_type: "think",
      detail: {
        "step_number" => 0,
        "prompt_preview" => "SENSITIVE_PROMPT",
        "response_preview" => "SENSITIVE_LLM_RESPONSE",
        "reasoning" => "SENSITIVE_REASONING",
        "tool_calls" => [
          { "name" => "execute_action",
            "arguments" => '{"action":"create_note","params":{"body":"SENSITIVE_TOOL_ARGS"}}' },
        ],
      })
    task_run.agent_session_steps.create!(position: 2, step_type: "execute",
      detail: { "action" => "create_note", "params" => { "text" => "SENSITIVE_PARAMS" }, "success" => true, "content_preview" => "SENSITIVE_RESULT" })
    task_run.agent_session_steps.create!(position: 3, step_type: "done",
      detail: { "message" => "SENSITIVE_DONE_MESSAGE" })
    task_run.agent_session_steps.create!(position: 4, step_type: "scratchpad_update",
      detail: { "content" => "SENSITIVE_SCRATCHPAD" })

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
    assert_no_match(/SENSITIVE_REASONING/, response.body,
      "Model reasoning is treated like LLM response — redacted for non-system agents")
    assert_no_match(/SENSITIVE_TOOL_ARGS/, response.body,
      "Tool call arguments can contain tenant content (note bodies, etc.) — redact for non-system agents")
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

  # ============================================================================
  # SECTION 6: Redispatch Queued Tasks
  # ============================================================================

  test "sys_admin sees redispatch button when queued tasks exist" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Q Agent", email: "q-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "Some queued task",
      max_steps: 10,
      status: "queued",
    )

    get "/system-admin/agent-runner"
    assert_response :success
    assert_match "Redispatch 1 queued task", response.body
  end

  test "sys_admin executes redispatch and gets flash message" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Q Agent", email: "q-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    task_run = AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "Queued task",
      max_steps: 10,
      status: "queued",
    )

    AgentRunnerDispatchService.stub :dispatch, ->(_tr) { nil } do
      post "/system-admin/agent-runner/actions/redispatch-queued"
    end

    assert_redirected_to "/system-admin/agent-runner"
    assert_match(/Redispatched 1 of 1 queued task/, flash[:notice].to_s)
    assert_equal "queued", task_run.reload.status
  end

  test "redispatch reports failures without aborting" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Q Agent", email: "q-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    2.times do |i|
      AiAgentTaskRun.create!(
        tenant: @primary_tenant,
        ai_agent: ai_agent,
        initiated_by: @sys_admin_user,
        task: "Task #{i}",
        max_steps: 10,
        status: "queued",
      )
    end

    call_count = 0
    boom = ->(_tr) {
      call_count += 1
      raise StandardError, "boom" if call_count == 1
    }
    AgentRunnerDispatchService.stub :dispatch, boom do
      post "/system-admin/agent-runner/actions/redispatch-queued"
    end

    assert_redirected_to "/system-admin/agent-runner"
    assert_match(/Redispatched 1 of 2 queued tasks\. 1 failed\./, flash[:notice].to_s)
  end

  test "redispatch restores request tenant scope even when a task dispatch fails" do
    # Create a task run in a non-primary tenant so a leaked scope would be visible.
    @primary_tenant.add_user!(@sys_admin_user)
    @other_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @other_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Q Agent", email: "q-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @other_tenant.add_user!(ai_agent)
    AiAgentTaskRun.create!(
      tenant: @other_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "task",
      max_steps: 10,
      status: "queued",
    )
    Tenant.clear_thread_scope

    AgentRunnerDispatchService.stub :dispatch, ->(_tr) { raise "explode" } do
      post "/system-admin/agent-runner/actions/redispatch-queued"
    end
    assert_redirected_to "/system-admin/agent-runner"
  end

  test "non-sys-admin cannot redispatch queued tasks" do
    @primary_tenant.add_user!(@non_sys_admin_user)
    tu = @primary_tenant.tenant_users.find_by(user: @non_sys_admin_user)
    tu.add_role!('admin')

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_sys_admin_user, tenant: @primary_tenant)

    post "/system-admin/agent-runner/actions/redispatch-queued"
    assert_response :forbidden
  end

  # ============================================================================
  # SECTION 7: Cancel Task Run
  # ============================================================================

  test "sys_admin can cancel a running task run" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Run Agent", email: "run-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    task_run = AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "running task",
      max_steps: 10,
      status: "running",
      started_at: Time.current,
    )

    post cancel_system_admin_task_run_path(task_run.id)

    assert_redirected_to system_admin_task_run_path(task_run.id)
    task_run.reload
    assert_equal "cancelled", task_run.status
    assert_equal "Cancelled by admin", task_run.error
    assert_not_nil task_run.completed_at
  end

  test "sys_admin can cancel a queued task run" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Q Agent", email: "qc-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    task_run = AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "queued task",
      max_steps: 10,
      status: "queued",
    )

    post cancel_system_admin_task_run_path(task_run.id)

    assert_redirected_to system_admin_task_run_path(task_run.id)
    assert_equal "cancelled", task_run.reload.status
  end

  test "cancel deletes active api tokens for the task run" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Tok Agent", email: "tok-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    task_run = AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "task",
      max_steps: 10,
      status: "running",
      started_at: Time.current,
    )
    token = ApiToken.create_internal_token(
      user: ai_agent,
      tenant: @primary_tenant,
      context: task_run,
      expires_in: 1.hour,
    )

    post cancel_system_admin_task_run_path(task_run.id)

    # Internal tokens are hidden by the default scope, so query unscoped
    refreshed = ApiToken.unscope(where: :internal).unscope(where: :tenant_id).find(token.id)
    assert_not_nil refreshed.deleted_at, "API token should be marked deleted"
  end

  test "cancel refuses for already-completed task" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "C Agent", email: "c-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    task_run = AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "task",
      max_steps: 10,
      status: "completed",
      success: true,
      completed_at: 1.minute.ago,
    )

    post cancel_system_admin_task_run_path(task_run.id)

    assert_redirected_to system_admin_task_run_path(task_run.id)
    follow_redirect!
    assert_equal "completed", task_run.reload.status
  end

  test "cancel returns 404 for unknown task" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    post cancel_system_admin_task_run_path(SecureRandom.uuid)
    assert_response :not_found
  end

  test "non-sys-admin cannot cancel a task run" do
    @primary_tenant.add_user!(@non_sys_admin_user)
    tu = @primary_tenant.tenant_users.find_by(user: @non_sys_admin_user)
    tu.add_role!('admin')

    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as(@non_sys_admin_user, tenant: @primary_tenant)

    post cancel_system_admin_task_run_path(SecureRandom.uuid)
    assert_response :forbidden
  end

  test "show_task_run renders cancel button for running task" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    email = "cancel-#{SecureRandom.hex(4)}@test.com"
    ai_agent = User.create!(name: "Cancel Agent", email: email, user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    task_run = AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "task",
      max_steps: 10,
      status: "running",
      started_at: Time.current,
    )

    get system_admin_task_run_path(task_run.id)
    assert_response :success
    assert_match "Cancel Task Run", response.body
  end

  test "show_task_run hides cancel button for completed task" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    Collective.scope_thread_to_collective(subdomain: @primary_tenant.subdomain, handle: nil)
    ai_agent = User.create!(name: "Done Agent", email: "done-#{SecureRandom.hex(4)}@test.com", user_type: "ai_agent", parent_id: @sys_admin_user.id)
    @primary_tenant.add_user!(ai_agent)
    task_run = AiAgentTaskRun.create!(
      tenant: @primary_tenant,
      ai_agent: ai_agent,
      initiated_by: @sys_admin_user,
      task: "task",
      max_steps: 10,
      status: "completed",
      success: true,
      completed_at: 1.minute.ago,
    )

    get system_admin_task_run_path(task_run.id)
    assert_response :success
    assert_no_match(/Cancel Task Run/, response.body)
  end

  # ============================================================================
  # SECTION 8: System Health Panel
  # ============================================================================

  test "dashboard includes DB pool and Redis health stats" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin"
    assert_response :success

    # New labels introduced by the system health panel — not present before.
    assert_match(/DB Pool/, response.body)
    assert_match(/clients/, response.body)
    assert_match(/waiting/, response.body)
  end

  test "dashboard markdown includes system health section" do
    @primary_tenant.add_user!(@sys_admin_user)
    host! "#{@primary_tenant.subdomain}.#{ENV['HOSTNAME']}"
    sign_in_as_admin(@sys_admin_user, tenant: @primary_tenant)

    get "/system-admin", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/System Health/, response.body)
    assert_match(/DB pool:/, response.body)
  end
end
