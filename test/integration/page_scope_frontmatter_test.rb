require "test_helper"

# Feed pages declare their fixed filters in markdown frontmatter as a
# `scope:` attribute (search syntax), and their current refinements as
# `query:`. Agents can paste the scope into /search to reproduce the page's
# content — one navigation calculus. See docs/NAVIGATION_DESIGN.md
# ("Feeds are queries").
class PageScopeFrontmatterTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    api_token = ApiToken.create!(tenant: @tenant, user: @user, scopes: ApiToken.valid_scopes)
    @headers = {
      "Authorization" => "Bearer #{api_token.plaintext_token}",
      "Accept" => "text/markdown",
    }
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
  end

  # The YAML frontmatter block between the first two `---` lines.
  def frontmatter(body)
    body[/\A.*?^---$(.*?)^---$/m, 1] || ""
  end

  test "home feed declares its fixed scope and default query" do
    get "/", headers: @headers
    assert_response :success
    fm = frontmatter(response.body)
    assert_includes fm, "\nscope: visibility:public\n"
    assert_includes fm, "\nquery: list:tuned_in -subtype:comment\n"
  end

  test "home feed query reflects the viewer's refinement" do
    get "/", params: { q: "type:note" }, headers: @headers
    assert_response :success
    fm = frontmatter(response.body)
    assert_includes fm, "\nscope: visibility:public\n"
    assert_includes fm, "\nquery: type:note\n"
  end

  test "search page declares the current query and no scope" do
    get "/search", params: { q: "type:note budget" }, headers: @headers
    assert_response :success
    fm = frontmatter(response.body)
    assert_includes fm, "\nquery: type:note budget\n"
    assert_no_match(/^scope:/, fm)
  end

  test "search page with no query omits both keys" do
    get "/search", headers: @headers
    assert_response :success
    fm = frontmatter(response.body)
    assert_no_match(/^scope:/, fm)
    assert_no_match(/^query:/, fm)
  end

  test "profile page declares a creator scope" do
    handle = @user.tenant_user.handle
    get "/u/#{handle}", headers: @headers
    assert_response :success
    assert_includes frontmatter(response.body), "\nscope: visibility:public creator:@#{handle}\n"
  end

  test "list activity page declares a list scope" do
    list = @user.primary_user_list_in!(@tenant)
    get "/lists/#{list.truncated_id}", headers: @headers
    assert_response :success
    assert_includes frontmatter(response.body), "\nscope: visibility:public list:#{list.truncated_id}\n"
  end

  test "collective page declares a collective scope" do
    get @collective.path.to_s, headers: @headers
    assert_response :success
    assert_includes frontmatter(response.body), "\nscope: collective:#{@collective.handle}\n"
  end

  test "private workspace page declares the private zone as its scope" do
    workspace = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "My Workspace",
      handle: "scope-test-workspace-#{SecureRandom.hex(4)}",
      collective_type: "private_workspace"
    )
    workspace.add_user!(@user)

    get workspace.path.to_s, headers: @headers
    assert_response :success
    assert_includes frontmatter(response.body), "\nscope: visibility:private\n"
  end
end
