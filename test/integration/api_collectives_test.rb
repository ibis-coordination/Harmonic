require "test_helper"

class ApiCollectivesTest < ActionDispatch::IntegrationTest
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

  def api_path(path = "")
    "/api/v1/collectives#{path}"
  end

  # Index
  test "index returns user's collectives" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    assert body.any? { |s| s["id"] == @collective.id }
  end

  test "index only returns collectives user is member of" do
    other_user = create_user(email: "other@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    other_collective = Collective.create!(tenant: @tenant, created_by: other_user, name: "Other Collective", handle: "other-collective")
    # Don't add @user to other_collective
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_not body.any? { |s| s["id"] == other_collective.id }
  end

  # Show
  test "show returns a collective by id" do
    get api_path("/#{@collective.id}"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @collective.id, body["id"]
    assert_equal @collective.name, body["name"]
    assert_equal @collective.handle, body["handle"]
  end

  test "show returns a collective by handle" do
    get api_path("/#{@collective.handle}"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @collective.id, body["id"]
  end

  test "show returns 404 for non-existent collective" do
    get api_path("/nonexistent"), headers: @headers
    assert_response :not_found
  end

  test "show returns 404 for collective user is not member of" do
    other_user = create_user(email: "other@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    other_collective = Collective.create!(tenant: @tenant, created_by: other_user, name: "Other Collective", handle: "other-collective")
    get api_path("/#{other_collective.id}"), headers: @headers
    assert_response :not_found
  end

  # === v1 API is read-only — collective writes happen via action routes ===

  test "v1 collectives API has no write routes (read-only API)" do
    assert_raises(ActionController::RoutingError) do
      post api_path, params: { name: "x", handle: "y" }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      put api_path("/#{@collective.id}"), params: { name: "x" }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      delete api_path("/#{@collective.id}"), headers: @headers
    end
  end
end
