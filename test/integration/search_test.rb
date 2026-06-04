# typed: false

require "test_helper"

class SearchTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user
    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @plaintext_token = @api_token.plaintext_token
    @headers = {
      "Authorization" => "Bearer #{@plaintext_token}",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV["HOSTNAME"]}"

    # Create some test data
    @note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Test note for search")
    SearchIndexer.reindex(@note)
  end

  def search_path
    "/search"
  end

  # HTML tests

  test "GET search returns HTML" do
    get search_path, headers: @headers.merge("Accept" => "text/html")
    assert_response :success
    assert_match "Search Results", response.body
  end

  test "GET search with query parameter returns matching results" do
    get search_path, params: { q: "test", cycle: "all" }, headers: @headers.merge("Accept" => "text/html")
    assert_response :success
    assert_match @note.title, response.body
  end

  test "GET search with no results shows empty state" do
    get search_path, params: { q: "nonexistentquery12345", cycle: "all" }, headers: @headers.merge("Accept" => "text/html")
    assert_response :success
    # Either HTML or markdown may show an empty state
    assert(response.body.include?("No results found") || response.body.include?("0 results"))
  end

  # Markdown tests

  test "GET search with Accept text/markdown returns markdown" do
    get search_path, params: { cycle: "all" }, headers: @headers.merge("Accept" => "text/markdown")
    assert_response :success
    assert response.content_type.starts_with?("text/markdown")
    assert_match "# Search Results", response.body
  end

  test "GET search markdown includes results" do
    get search_path, params: { q: "test", cycle: "all" }, headers: @headers.merge("Accept" => "text/markdown")
    assert_response :success
    assert_match @note.title, response.body
  end

  # JSON tests

  test "GET search.json returns JSON" do
    get "#{search_path}.json", params: { cycle: "all" }, headers: @headers
    assert_response :success
    assert_equal "application/json", response.media_type

    json = JSON.parse(response.body)
    assert json.key?("results")
    assert json.key?("total_count")
    assert json.key?("query")
  end

  test "GET search.json with query returns matching results" do
    get "#{search_path}.json", params: { q: "test", cycle: "all" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["results"].any? { |r| r["item_id"] == @note.id }
  end

  test "GET search.json returns cursor for pagination" do
    # Create multiple items
    5.times do |i|
      note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Paginated note #{i}")
      SearchIndexer.reindex(note)
    end

    get "#{search_path}.json", params: { q: "cycle:all", per_page: 2 }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["next_cursor"].present?
    assert_equal 2, json["results"].length
  end

  # Filter tests

  test "GET search with type filter returns only specified types" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user, question: "Test decision?")
    SearchIndexer.reindex(decision)

    get "#{search_path}.json", params: { q: "type:note cycle:all" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["results"].all? { |r| r["item_type"] == "Note" }
    assert json["results"].none? { |r| r["item_type"] == "Decision" }
  end

  test "GET search with filters parameter works" do
    get "#{search_path}.json", params: { q: "cycle:all", filters: "mine" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    # All results should be created by the current user
    assert json["results"].present?
  end

  # Sort tests

  test "GET search with sort_by parameter works" do
    get "#{search_path}.json", params: { q: "sort:newest cycle:all" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert json["results"].is_a?(Array)
  end

  # Group tests

  test "GET search with group_by parameter works in HTML" do
    get search_path, params: { q: "group:item_type cycle:all" }, headers: @headers.merge("Accept" => "text/html")
    assert_response :success
  end

  # Action tests

  test "GET search/actions returns list of actions" do
    get "/search/actions", headers: @headers.merge("Accept" => "text/markdown")
    assert_response :success
    assert_match "search(q)", response.body
  end

  test "GET search/actions/search describes the search action" do
    get "/search/actions/search", headers: @headers.merge("Accept" => "text/markdown")
    assert_response :success
    assert_match "Action: `search`", response.body
    assert_match "Parameters", response.body
  end

  test "POST search/actions/search redirects to GET with query" do
    post "/search/actions/search",
      params: { q: "type:note budget" },
      headers: @headers.merge("Accept" => "text/markdown", "Content-Type" => "application/x-www-form-urlencoded")
    assert_response :redirect
    assert_match "/search?q=", response.location
    assert_match "type%3Anote", response.location
  end

  test "GET search markdown returns valid response" do
    get search_path, headers: @headers.merge("Accept" => "text/markdown")
    assert_response :success
    # Verify page renders with search syntax help
    assert_match "Search Syntax", response.body, "Should show search syntax help"
  end

  test "GET search markdown includes path with query in frontmatter" do
    get search_path, params: { q: "test query" }, headers: @headers.merge("Accept" => "text/markdown")
    assert_response :success
    # The frontmatter should include path with the query
    assert_match "path: /search?q=", response.body
  end

  # People search — Phase 1 of discoverability

  test "search matches a user by exact handle (HTML)" do
    target = create_user(email: "searchable-#{SecureRandom.hex(4)}@example.com", name: "Searchable Person")
    @tenant.add_user!(target)
    @collective.add_user!(target)
    tu = target.tenant_users.find_by(tenant_id: @tenant.id)
    sign_in_as(@user, tenant: @tenant)
    get search_path, params: { q: tu.handle, cycle: "all" }
    assert_response :success
    assert_select "section.pulse-people-results"
    assert_select ".pulse-people-results", text: /Searchable Person/
    assert_select ".pulse-people-results", text: /@#{Regexp.escape(tu.handle)}/
  end

  test "search matches a user by case-insensitive partial name (HTML)" do
    create_user_in_tenant(name: "Aurora Borealis Unique-#{SecureRandom.hex(4)}")
    sign_in_as(@user, tenant: @tenant)
    get search_path, params: { q: "aurora", cycle: "all" }
    assert_response :success
    assert_select ".pulse-people-results", text: /Aurora Borealis/
  end

  test "search hides users the viewer has blocked, either direction (HTML)" do
    blocked = create_user_in_tenant(name: "Blocked Person Unique-#{SecureRandom.hex(4)}")
    UserBlock.create!(blocker: @user, blocked: blocked, tenant: @tenant)
    sign_in_as(@user, tenant: @tenant)
    get search_path, params: { q: "blocked person", cycle: "all" }
    assert_response :success
    assert_select ".pulse-people-results", text: /Blocked Person/, count: 0
  end

  test "search excludes collective_identity users (they have no profile path)" do
    # Collective-identity users back a collective's avatar/identity. Surfacing
    # them in user search is meaningless (their `path` resolves via their
    # owned collective, which may be nil) and clicks dead-end on empty hrefs.
    identity_collective = Collective.create!(
      tenant: @tenant, name: "Identity #{SecureRandom.hex(4)}",
      handle: "ident-#{SecureRandom.hex(4)}",
      collective_type: "standard", created_by: @user, updated_by: @user,
    )
    # The identity user is auto-created by the collective; find it.
    identity_user = identity_collective.identity_user
    assert identity_user.present?, "expected collective to have an identity_user"
    assert identity_user.collective_identity?

    sign_in_as(@user, tenant: @tenant)
    # Search by the identity user's handle directly so a match WOULD return them if not excluded.
    tu = identity_user.tenant_users.find_by(tenant_id: @tenant.id)
    get search_path, params: { q: tu.handle, cycle: "all" }
    assert_response :success
    assert_select ".pulse-people-results", text: /@#{Regexp.escape(tu.handle)}/, count: 0
  end

  test "search suppresses People section when a content-only filter is applied" do
    create_user_in_tenant(name: "Targetable Bob Unique-#{SecureRandom.hex(4)}")
    sign_in_as(@user, tenant: @tenant)
    # `status:` is content-only. Even though "targetable" would match the name,
    # the presence of a content-only filter signals the search is for content.
    get search_path, params: { q: "status:closed targetable", cycle: "all" }
    assert_response :success
    assert_select ".pulse-people-results", count: 0
  end

  test "search suppresses People section when type: filter is applied" do
    create_user_in_tenant(name: "Targetable2 Bob Unique-#{SecureRandom.hex(4)}")
    sign_in_as(@user, tenant: @tenant)
    get search_path, params: { q: "type:note targetable2", cycle: "all" }
    assert_response :success
    assert_select ".pulse-people-results", count: 0
  end

  test "search suppresses People section when a user-handle filter (e.g. creator:) is applied" do
    create_user_in_tenant(name: "Targetable3 Bob Unique-#{SecureRandom.hex(4)}")
    sign_in_as(@user, tenant: @tenant)
    get search_path, params: { q: "creator:@anyone targetable3", cycle: "all" }
    assert_response :success
    assert_select ".pulse-people-results", count: 0
  end

  test "search keeps People section when only the `collective:` operator is set" do
    target = create_user_in_tenant(name: "InCollectiveBob Unique-#{SecureRandom.hex(4)}")
    coll = Collective.create!(
      tenant: @tenant, name: "Shareable", handle: "share-#{SecureRandom.hex(4)}",
      collective_type: "standard", created_by: @user, updated_by: @user,
    )
    coll.add_user!(@user)
    coll.add_user!(target)
    sign_in_as(@user, tenant: @tenant)
    get search_path, params: { q: "collective:#{coll.handle} incollectivebob", cycle: "all" }
    assert_response :success
    assert_select ".pulse-people-results", text: /InCollectiveBob/
  end

  test "search collective: filter returns no people when the viewer is not a member of the collective" do
    # Privacy: a non-member must NOT be able to enumerate members of a
    # collective they can't see by filtering people search.
    secret_member = create_user_in_tenant(name: "SecretMemberBob Unique-#{SecureRandom.hex(4)}")
    other_owner = create_user(email: "owner-#{SecureRandom.hex(4)}@example.com", name: "Other Owner")
    @tenant.add_user!(other_owner)
    private_coll = Collective.create!(
      tenant: @tenant, name: "Secret", handle: "secret-#{SecureRandom.hex(4)}",
      collective_type: "standard", created_by: other_owner, updated_by: other_owner,
    )
    private_coll.add_user!(secret_member)
    # @user is NOT a member of private_coll.

    sign_in_as(@user, tenant: @tenant)
    get search_path, params: { q: "collective:#{private_coll.handle} secretmemberbob", cycle: "all" }
    assert_response :success
    assert_select ".pulse-people-results", text: /SecretMemberBob/, count: 0
  end

  test "search respects `collective:` filter — only returns users who are members of that collective" do
    in_collective = create_user(email: "incoll-#{SecureRandom.hex(4)}@example.com", name: "Bob InCollective")
    out_of_collective = create_user(email: "outcoll-#{SecureRandom.hex(4)}@example.com", name: "Bob OutOfCollective")
    @tenant.add_user!(in_collective)
    @tenant.add_user!(out_of_collective)

    other_collective = Collective.create!(
      tenant: @tenant, name: "OtherColl",
      handle: "otherc-#{SecureRandom.hex(4)}",
      collective_type: "standard", created_by: @user, updated_by: @user,
    )
    # The viewer must be a member to see who else is in the collective (the
    # collective: filter is privacy-gated).
    other_collective.add_user!(@user)
    other_collective.add_user!(in_collective)
    # out_of_collective intentionally NOT added.

    sign_in_as(@user, tenant: @tenant)
    get search_path, params: { q: "collective:#{other_collective.handle} bob", cycle: "all" }
    assert_response :success
    assert_select ".pulse-people-results", text: /Bob InCollective/
    assert_select ".pulse-people-results", text: /Bob OutOfCollective/, count: 0
  end

  test "search has no People section when no users match (HTML)" do
    sign_in_as(@user, tenant: @tenant)
    get search_path, params: { q: "z" * 30, cycle: "all" }
    assert_response :success
    assert_select "section.pulse-people-results", count: 0
  end

  test "search markdown includes a People section" do
    create_user_in_tenant(name: "Mango Tango Unique-#{SecureRandom.hex(4)}")
    get search_path, params: { q: "mango", cycle: "all" }, headers: @headers.merge("Accept" => "text/markdown")
    assert_response :success
    assert_includes response.body, "## People"
    assert_includes response.body, "Mango Tango"
  end

  test "search JSON includes a `people` key" do
    target = create_user_in_tenant(name: "JsonPersonUnique-#{SecureRandom.hex(4)}")
    get search_path, params: { q: "jsonperson", cycle: "all" }, headers: @headers.merge("Accept" => "application/json")
    assert_response :success
    json = JSON.parse(response.body)
    assert json["people"].is_a?(Array)
    assert(json["people"].any? { |p| p["display_name"]&.include?("JsonPerson") }, "expected JSON people array to include the matching user")
  end

  private

  def create_user_in_tenant(name:)
    u = create_user(email: "u-#{SecureRandom.hex(4)}@example.com", name: name)
    @tenant.add_user!(u)
    @collective.add_user!(u)
    u
  end
end
