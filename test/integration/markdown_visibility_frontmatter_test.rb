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

  def visibility_for(body, action_name)
    # Grab the `visibility:` line within the action block keyed by name.
    # Block ends at the next `- name:` or the end of the actions list.
    match = body.match(/^\s*- name: #{Regexp.escape(action_name)}\b.*?(?=^\s*- name:|^---)/m)
    return nil unless match

    vis = match[0].match(/^\s*visibility: (public|private|shared)\b/)
    vis && vis[1]
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

    # Parse every action listed in the frontmatter and assert each is private.
    # Match only top-level action entries (exactly 2-space indent) — deeper
    # `- name:` lines inside `params:` blocks don't count.
    listed = response.body.scan(/^  - name: ([a-z_]+)\b/).flatten
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
end
