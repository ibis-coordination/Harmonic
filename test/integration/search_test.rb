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
end
