require "test_helper"

class ApiCommitmentsTest < ActionDispatch::IntegrationTest
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
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  def api_path(path = "")
    "#{@collective.path}/api/v1/commitments#{path}"
  end

  # Index is not supported
  test "index returns 404 with helpful message" do
    get api_path, headers: @headers
    assert_response :not_found
    body = JSON.parse(response.body)
    assert body["message"].include?("cycles")
  end

  # Show
  test "show returns a commitment" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    get api_path("/#{commitment.truncated_id}"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal commitment.id, body["id"]
    assert_equal commitment.title, body["title"]
    assert_equal commitment.truncated_id, body["truncated_id"]
    assert_equal commitment.critical_mass, body["critical_mass"]
  end

  test "show returns 404 for non-existent commitment" do
    get api_path("/nonexistent"), headers: @headers
    assert_response :not_found
  end

  test "show with include=participants returns participants" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    get api_path("/#{commitment.truncated_id}?include=participants"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("participants")
  end

  test "show with include=backlinks returns backlinks" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    get api_path("/#{commitment.truncated_id}?include=backlinks"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("backlinks")
  end

  # === v1 API is read-only — commitment writes happen via action routes ===

  test "v1 commitments API has no write routes (read-only API)" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    assert_raises(ActionController::RoutingError) do
      post api_path, params: { title: "x", critical_mass: 1 }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      put api_path("/#{commitment.truncated_id}"), params: { title: "x" }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      delete api_path("/#{commitment.truncated_id}"), headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      post api_path("/#{commitment.truncated_id}/join"), params: { committed: true }.to_json, headers: @headers
    end
  end
end
