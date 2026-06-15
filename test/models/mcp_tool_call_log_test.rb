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
end
