require "test_helper"

# Every action listed in a page's YAML frontmatter carries a `visibility:`
# attribute so the agent can read the audience tier directly off the action
# rather than inferring it from the path. The value is sourced from
# Mcp::AudienceResolver — same gate the server uses to validate the agent's
# declared `context.visibility`.
class MarkdownVisibilityFrontmatterTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective # non-main collective
    @collective.enable_api!
    @main_collective = @tenant.main_collective
    @main_collective&.enable_api!
    @user = @global_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # Parse the frontmatter as standard YAML (as the real consumers do) rather than
  # matching indentation — Psych emits actions at column 0 and their params at a
  # deeper indent, so an indent-based scan can't tell them apart.
  def frontmatter_actions(body)
    return [] unless body.start_with?("---\n")

    end_index = body.index("\n---\n", 4)
    return [] unless end_index

    parsed = YAML.safe_load(body[4...end_index], permitted_classes: [Time, Symbol]) || {}
    Array(parsed["actions"])
  end

  def visibility_for(body, action_name)
    action = frontmatter_actions(body).find { |a| a["name"] == action_name }
    action && action["visibility"]
  end

  test "agent-private actions carry visibility: private in /whoami frontmatter" do
    # AI agents auth via API token, not session. Sign in via Bearer.
    agent = create_ai_agent(parent: @user, name: "Visibility Test Agent",
                            agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    token = ApiToken.create!(tenant: @tenant, user: agent, scopes: ApiToken.valid_scopes)

    get "/whoami", headers: {
      "Accept" => "text/markdown",
      "Authorization" => "Bearer #{token.plaintext_token}",
    }
    assert_response :success
    assert_equal "private", visibility_for(response.body, "update_scratchpad"),
                 "update_scratchpad on /whoami should resolve to private"
  end

  test "actions on a non-main collective carry visibility: shared" do
    note = create_note(text: "Test note", created_by: @user)
    sign_in_as(@user, tenant: @tenant)

    get note.path, headers: { "Accept" => "text/markdown" }
    assert_response :success
    # confirm_read is a normal collective action — tier follows the collective.
    assert_equal "shared", visibility_for(response.body, "confirm_read"),
                 "confirm_read on a non-main-collective note should resolve to shared"
  end

  test "every notifications action carries visibility: private (path-based rule, not just enumerated names)" do
    # /notifications is intrinsically private — every action on it (dismiss,
    # dismiss_all, dismiss_for_collective, dismiss_for_chat, mark_read,
    # mark_all_read, mark_read_for_collective, ...) writes only to the acting
    # user's inbox. The rule is path-based: actions under the notifications
    # controller all resolve to `private`. Enumerating names is fragile; a
    # new notifications action added to the controller should inherit `private`
    # without anyone needing to update the resolver.
    sign_in_as(@user, tenant: @tenant)
    get "/notifications", headers: { "Accept" => "text/markdown" }
    assert_response :success

    # Assert every listed action resolves to private (path-based rule).
    listed = frontmatter_actions(response.body).map { |a| a["name"] }
    assert listed.any?, "expected notifications frontmatter to list at least one action"

    listed.each do |action_name|
      assert_equal "private", visibility_for(response.body, action_name),
                   "expected #{action_name} on /notifications to resolve to private"
    end
  end

  test "actions on the main collective carry visibility: public" do
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @main_collective.handle)
    note = create_note(text: "Main note", collective: @main_collective, created_by: @user)
    sign_in_as(@user, tenant: @tenant)

    get note.path, headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_equal "public", visibility_for(response.body, "confirm_read"),
                 "confirm_read on a main-collective note should resolve to public"
  end

  test "create_automation_rule on an agent-scoped route carries visibility: shared (not public via main-collective fallback)" do
    # User/agent routes have no :collective_handle in the path, so
    # `current_collective` falls back to the tenant's main collective.
    # If create_automation_rule used :by_collective, it would resolve to
    # :public via that fallback — wrong for a config record whose YAML can
    # reference secrets. The static :shared retag guards against that; pin
    # it at runtime so the fallback regression can't return silently.
    @tenant.set_feature_flag!("automations", true)
    agent = create_ai_agent(parent: @user, name: "Automation Visibility Agent")
    @tenant.add_user!(agent)
    sign_in_as(@user, tenant: @tenant)
    get "/ai-agents/#{agent.handle}/automations/new", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_equal "shared", visibility_for(response.body, "create_automation_rule"),
                 "create_automation_rule on /ai-agents/:handle/automations/new must be shared, not public"
  end
end
