require "test_helper"

class McpToolCallLogTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @agent = create_ai_agent(parent: @user, name: "Audit Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@agent)
    @token = ApiToken.create!(tenant: @tenant, user: @agent, scopes: ApiToken.valid_scopes)
  end

  def teardown
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  test "creates a log entry with required fields" do
    log = McpToolCallLog.create!(
      tenant: @tenant,
      user: @agent,
      api_token: @token,
      tool_name: "fetch_page",
      arguments: { "path" => "/whoami" },
      status: "ok",
      duration_ms: 42,
      request_id: "req-abc"
    )

    assert log.persisted?
    assert_equal "fetch_page", log.tool_name
    assert_equal({ "path" => "/whoami" }, log.arguments)
    assert_equal "ok", log.status
    assert_equal 42, log.duration_ms
    assert_equal "req-abc", log.request_id
    assert_equal @agent, log.user
    assert_equal @token, log.api_token
    assert_equal @tenant, log.tenant
  end

  test "requires tool_name" do
    log = McpToolCallLog.new(tenant: @tenant, user: @agent, api_token: @token, status: "ok", duration_ms: 1)
    assert_not log.valid?
    assert_includes log.errors[:tool_name], "can't be blank"
  end

  test "requires status" do
    log = McpToolCallLog.new(tenant: @tenant, user: @agent, api_token: @token, tool_name: "search", duration_ms: 1)
    assert_not log.valid?
    assert_includes log.errors[:status], "can't be blank"
  end

  test "validates status is in allowed set" do
    log = McpToolCallLog.new(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "search", status: "weird", duration_ms: 1
    )
    assert_not log.valid?
    assert_includes log.errors[:status], "is not included in the list"
  end

  test "accepts each known status" do
    ["pending", "ok", "tool_error", "unknown_tool"].each do |s|
      log = McpToolCallLog.new(
        tenant: @tenant, user: @agent, api_token: @token,
        tool_name: "search", status: s, duration_ms: 1, arguments: {}
      )
      assert log.valid?, "expected status=#{s} to be valid: #{log.errors.full_messages.inspect}"
    end
  end

  test "requires non-negative duration_ms" do
    log = McpToolCallLog.new(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "search", status: "ok", duration_ms: -1
    )
    assert_not log.valid?
    assert_includes log.errors[:duration_ms], "must be greater than or equal to 0"
  end

  test "is auto-scoped by tenant" do
    other_tenant = create_tenant(subdomain: "other-audit-#{SecureRandom.hex(4)}")
    other_user = create_user
    other_tenant.add_user!(other_user)

    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)
    other_agent = create_ai_agent(parent: other_user, name: "Other Agent", agent_configuration: { "mode" => "external" })
    other_tenant.add_user!(other_agent)
    other_token = ApiToken.create!(tenant: other_tenant, user: other_agent, scopes: ApiToken.valid_scopes)
    McpToolCallLog.create!(
      tenant: other_tenant, user: other_agent, api_token: other_token,
      tool_name: "search", status: "ok", duration_ms: 1
    )

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    McpToolCallLog.create!(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "search", status: "ok", duration_ms: 1
    )

    assert_equal 1, McpToolCallLog.count
    assert_equal @tenant.id, McpToolCallLog.first.tenant_id
  end

  test "ai_agent_task_run_id is optional and nil by default" do
    log = McpToolCallLog.create!(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "fetch_page", arguments: {}, status: "ok", duration_ms: 1
    )
    assert_nil log.ai_agent_task_run_id
    assert_nil log.ai_agent_task_run
  end

  test "ai_agent_task_run can be associated" do
    task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: @agent, initiated_by: @user,
      task: "test", max_steps: 5, status: "running"
    )
    log = McpToolCallLog.create!(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "fetch_page", arguments: {}, status: "ok", duration_ms: 1,
      ai_agent_task_run: task_run
    )
    assert_equal task_run, log.ai_agent_task_run
  end

  test "recent scope orders newest first" do
    older = McpToolCallLog.create!(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "search", status: "ok", duration_ms: 1, created_at: 2.hours.ago
    )
    newer = McpToolCallLog.create!(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "fetch_page", status: "ok", duration_ms: 1, created_at: 1.minute.ago
    )

    assert_equal [newer, older], McpToolCallLog.recent.to_a
  end

  test "internal? and source_label reflect the ai_agent_task_run association" do
    external = McpToolCallLog.create!(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "search", status: "ok", duration_ms: 1
    )
    assert_not external.internal?
    assert_equal "External client", external.source_label

    task_run = AiAgentTaskRun.create!(
      tenant: @tenant, ai_agent: @agent, initiated_by: @user,
      task: "test", max_steps: 5, status: "running"
    )
    internal = McpToolCallLog.create!(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "search", status: "ok", duration_ms: 1, ai_agent_task_run: task_run
    )
    assert internal.internal?
    assert_equal "Internal task run", internal.source_label
  end

  test "logged_path returns the path argument, or nil when absent" do
    with_path = McpToolCallLog.new(arguments: { "path" => "/collectives/team/n/abc123", "action" => "add_comment" })
    assert_equal "/collectives/team/n/abc123", with_path.logged_path

    without_path = McpToolCallLog.new(arguments: { "query" => "budget" })
    assert_nil without_path.logged_path

    assert_nil McpToolCallLog.new(arguments: nil).logged_path
    assert_nil McpToolCallLog.new(arguments: { "path" => "" }).logged_path
  end

  test "logged_action_name returns the action for execute_action, nil otherwise" do
    action_call = McpToolCallLog.new(arguments: { "path" => "/x", "action" => "update_row" })
    assert_equal "update_row", action_call.logged_action_name

    fetch_call = McpToolCallLog.new(arguments: { "path" => "/x" })
    assert_nil fetch_call.logged_action_name

    assert_nil McpToolCallLog.new(arguments: nil).logged_action_name
  end

  test "intention returns the context intention, or nil when absent" do
    with_intention = McpToolCallLog.new(context: { "intention" => "Reply to Dan on the thread", "visibility" => "shared" })
    assert_equal "Reply to Dan on the thread", with_intention.intention

    assert_nil McpToolCallLog.new(context: { "visibility" => "shared" }).intention
    assert_nil McpToolCallLog.new(context: nil).intention
    assert_nil McpToolCallLog.new(context: { "intention" => "" }).intention
  end

  test "destroying the api_token nullifies the log's api_token_id (audit row survives)" do
    # Task-scoped internal tokens are destroyed on task completion. Logs
    # written during the task must survive that destroy — the audit trail
    # is the load-bearing thing, the token reference is incidental.
    log = McpToolCallLog.create!(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "execute_action", arguments: { "path" => "/x", "action" => "y" },
      status: "ok", duration_ms: 5
    )

    @token.destroy!

    log.reload
    assert_nil log.api_token_id
    assert log.persisted?
    assert_equal @agent, log.user
  end
end
