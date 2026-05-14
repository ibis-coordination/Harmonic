require "test_helper"

class ApiInfoTest < ActionDispatch::IntegrationTest
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
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  test "GET /api/v1 returns API metadata and a routes list" do
    get "/api/v1", headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_kind_of String, body["name"]
    assert_kind_of String, body["version"]
    assert_kind_of Array, body["routes"]
    body["routes"].each do |route|
      assert_kind_of String, route["path"]
      assert_kind_of Array, route["methods"]
      assert route["methods"].any?
    end
  end

  test "GET /api/v1 routes list reflects the actual Rails routes (drift protection)" do
    get "/api/v1", headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    response_paths = body["routes"].map { |r| r["path"] }.to_set

    expected_paths = collect_real_api_paths("/api/v1")

    missing = expected_paths - response_paths
    extra = response_paths - expected_paths
    assert_empty missing, "Info endpoint is missing real /api/v1 routes: #{missing.to_a.sort}"
    assert_empty extra, "Info endpoint lists paths that don't exist: #{extra.to_a.sort}"
  end

  # Collect every path under the given /api/v1 prefix, excluding Rails' auto-
  # generated /new and /edit routes which have no controller actions.
  def collect_real_api_paths(prefix)
    Rails.application.routes.routes
      .map { |r| r.path.spec.to_s.sub(/\(\.:format\)\z/, "") }
      .reject { |p| p.end_with?("/new") || p.end_with?("/edit") }
      .select { |p| p == prefix || p.start_with?("#{prefix}/") }
      .to_set
  end

  test "GET /api/v1 routes list includes key tenant-level resources" do
    get "/api/v1", headers: @headers
    body = JSON.parse(response.body)
    paths = body["routes"].map { |r| r["path"] }
    assert_includes paths, "/api/v1/notes"
    assert_includes paths, "/api/v1/decisions"
    assert_includes paths, "/api/v1/commitments"
    assert_includes paths, "/api/v1/cycles"
    assert_includes paths, "/api/v1/users"
  end

  test "GET /collectives/:handle/api/v1 returns collective-scoped routes" do
    get "#{@collective.path}/api/v1", headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    paths = body["routes"].map { |r| r["path"] }

    # Should contain collective-scoped paths, not the tenant-level ones
    assert paths.any? { |p| p.start_with?("/collectives/:collective_handle/api/v1") },
      "Expected collective-scoped paths, got #{paths.first(5).inspect}"
    refute paths.any? { |p| p == "/api/v1/notes" },
      "Tenant-level paths should not appear in the collective-scoped response"
  end

  test "GET /collectives/:handle/api/v1 routes list reflects the actual Rails routes" do
    get "#{@collective.path}/api/v1", headers: @headers
    body = JSON.parse(response.body)
    response_paths = body["routes"].map { |r| r["path"] }.to_set

    expected_paths = collect_real_api_paths("/collectives/:collective_handle/api/v1")
    assert_equal expected_paths, response_paths, "Collective-scoped /api/v1 routes drifted"
  end

  test "each route's methods list reflects the actual HTTP verbs for that path" do
    get "/api/v1", headers: @headers
    body = JSON.parse(response.body)
    notes_route = body["routes"].find { |r| r["path"] == "/api/v1/notes" }
    refute_nil notes_route
    # /api/v1/notes is a Rails `resources :notes` collection — index (GET) + create (POST)
    assert_includes notes_route["methods"], "GET"
    assert_includes notes_route["methods"], "POST"
  end
end
