require "test_helper"

class McpToolCallResourceTest < ActiveSupport::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    @agent = create_ai_agent(parent: @user, name: "Attribution Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@agent)
    @collective.add_user!(@agent)
    @token = ApiToken.create!(tenant: @tenant, user: @agent, scopes: ApiToken.valid_scopes)
    @log = McpToolCallLog.create!(
      tenant: @tenant, user: @agent, api_token: @token,
      tool_name: "execute_action", arguments: {},
      status: "ok", duration_ms: 1, request_id: "req-1"
    )
  end

  def teardown
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  test "rejects cross-tenant log_id (tenant_id must match log's tenant)" do
    # Build a log row in a different tenant.
    other_tenant = create_tenant(subdomain: "xtenant-#{SecureRandom.hex(4)}")
    other_user = create_user
    other_tenant.add_user!(other_user)
    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)
    other_collective = create_collective(tenant: other_tenant, created_by: other_user, handle: "xtenant-coll")
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_collective.handle)
    other_agent = create_ai_agent(parent: other_user, name: "Other Agent", agent_configuration: { "mode" => "external" })
    other_tenant.add_user!(other_agent)
    other_collective.add_user!(other_agent)
    other_token = ApiToken.create!(tenant: other_tenant, user: other_agent, scopes: ApiToken.valid_scopes)
    other_log = McpToolCallLog.create!(
      tenant: other_tenant, user: other_agent, api_token: other_token,
      tool_name: "execute_action", arguments: {}, status: "ok", duration_ms: 1
    )

    # Switch back to current tenant and attempt to attribute a current-tenant
    # resource to the other-tenant log row.
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    row = McpToolCallResource.new(
      tenant: @tenant,
      mcp_tool_call_log_id: other_log.id,
      resource: note,
      resource_collective: @collective,
      action_name: "create_note"
    )

    # Cross-tenant references are blocked by McpToolCallLog's tenant-scoped
    # default scope: belongs_to :mcp_tool_call_log tries to load the log,
    # tenant scoping filters it out, the load returns nil, and Rails marks
    # the record invalid with "Mcp tool call log must exist". This regression
    # test locks that defense in place.
    assert_not row.valid?, "expected tenant-mismatched attribution row to be invalid"
    assert_includes row.errors[:mcp_tool_call_log], "must exist"
  end

  test "creates a resource attribution row with required fields" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    row = McpToolCallResource.create!(
      tenant: @tenant,
      mcp_tool_call_log: @log,
      resource: note,
      resource_collective: @collective,
      action_name: "create_note",
      display_path: "/c/#{@collective.handle}/n/#{note.truncated_id}"
    )

    assert row.persisted?
    assert_equal "create_note", row.action_name
    assert_equal note, row.resource
    assert_equal @log, row.mcp_tool_call_log
    assert_equal @collective, row.resource_collective
    assert_equal @tenant, row.tenant
  end

  test "requires action_name" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    row = McpToolCallResource.new(
      tenant: @tenant, mcp_tool_call_log: @log,
      resource: note, resource_collective: @collective
    )
    assert_not row.valid?
    assert_includes row.errors[:action_name], "can't be blank"
  end

  test "auto-fills tenant from mcp_tool_call_log when omitted" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    row = McpToolCallResource.create!(
      mcp_tool_call_log: @log,
      resource: note, resource_collective: @collective,
      action_name: "create_note"
    )
    assert_equal @tenant.id, row.tenant_id
  end

  test "requires resource_collective" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    row = McpToolCallResource.new(
      tenant: @tenant, mcp_tool_call_log: @log,
      resource: note, action_name: "create_note"
    )
    assert_not row.valid?
    assert_includes row.errors[:resource_collective], "must exist"
  end

  test "rejects mismatched resource_collective" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    other_collective = create_collective(tenant: @tenant, created_by: @user, handle: "other-#{SecureRandom.hex(4)}")
    row = McpToolCallResource.new(
      tenant: @tenant, mcp_tool_call_log: @log,
      resource: note, resource_collective: other_collective,
      action_name: "create_note"
    )
    assert_not row.valid?
    assert_includes row.errors[:resource_collective], "must match resource's collective"
  end

  test "is auto-scoped by tenant" do
    other_tenant = create_tenant(subdomain: "other-attr-#{SecureRandom.hex(4)}")
    other_user = create_user
    other_tenant.add_user!(other_user)
    Tenant.scope_thread_to_tenant(subdomain: other_tenant.subdomain)
    other_collective = create_collective(tenant: other_tenant, created_by: other_user, handle: "other-tenant-coll")
    Collective.scope_thread_to_collective(subdomain: other_tenant.subdomain, handle: other_collective.handle)
    other_agent = create_ai_agent(parent: other_user, name: "Other Attr", agent_configuration: { "mode" => "external" })
    other_tenant.add_user!(other_agent)
    other_collective.add_user!(other_agent)
    other_token = ApiToken.create!(tenant: other_tenant, user: other_agent, scopes: ApiToken.valid_scopes)
    other_log = McpToolCallLog.create!(
      tenant: other_tenant, user: other_agent, api_token: other_token,
      tool_name: "execute_action", arguments: {}, status: "ok", duration_ms: 1
    )
    other_note = create_note(tenant: other_tenant, collective: other_collective, created_by: other_agent)
    McpToolCallResource.create!(
      tenant: other_tenant, mcp_tool_call_log: other_log,
      resource: other_note, resource_collective: other_collective, action_name: "create_note"
    )

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    McpToolCallResource.create!(
      tenant: @tenant, mcp_tool_call_log: @log,
      resource: note, resource_collective: @collective, action_name: "create_note"
    )

    assert_equal 1, McpToolCallResource.count
    assert_equal @tenant.id, McpToolCallResource.first.tenant_id
  end

  test "for_resource returns attribution rows for a given record" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    row = McpToolCallResource.create!(
      tenant: @tenant, mcp_tool_call_log: @log,
      resource: note, resource_collective: @collective, action_name: "create_note"
    )
    assert_equal [row], McpToolCallResource.for_resource(note)
  end

  test "McpToolCallLog has_many mcp_tool_call_resources" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    note2 = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    McpToolCallResource.create!(tenant: @tenant, mcp_tool_call_log: @log, resource: note1, resource_collective: @collective,
                                action_name: "create_note")
    McpToolCallResource.create!(tenant: @tenant, mcp_tool_call_log: @log, resource: note2, resource_collective: @collective,
                                action_name: "create_note")
    assert_equal 2, @log.reload.mcp_tool_call_resources.size
  end

  test "display_path is readable as the stored column value" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @agent)
    row = McpToolCallResource.create!(
      tenant: @tenant, mcp_tool_call_log: @log,
      resource: note, resource_collective: @collective, action_name: "create_note",
      display_path: "/some/path"
    )
    assert_equal "/some/path", row.display_path
  end
end
