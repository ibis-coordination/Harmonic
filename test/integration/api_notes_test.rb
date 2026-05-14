require "test_helper"

class ApiNotesTest < ActionDispatch::IntegrationTest
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
    "#{@collective.path}/api/v1/notes#{path}"
  end

  # Index is not supported for notes
  test "index returns 404 with helpful message" do
    get api_path, headers: @headers
    assert_response :not_found
    body = JSON.parse(response.body)
    assert body["message"].include?("cycles")
  end

  # Show
  test "show returns a note" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    get api_path("/#{note.truncated_id}"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal note.id, body["id"]
    assert_equal note.title, body["title"]
    assert_equal note.text, body["text"]
    assert_equal note.truncated_id, body["truncated_id"]
  end

  test "show returns 404 for non-existent note" do
    get api_path("/nonexistent"), headers: @headers
    assert_response :not_found
  end

  test "show with include=backlinks returns backlinks" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    get api_path("/#{note.truncated_id}?include=backlinks"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("backlinks")
  end

  test "show with include=history_events returns history events" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    get api_path("/#{note.truncated_id}?include=history_events"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("history_events")
  end

  # === v1 API is read-only — note writes happen via action routes ===

  test "v1 notes API has no write routes (read-only API)" do
    assert_raises(ActionController::RoutingError) do
      post api_path, params: { title: "x", text: "y" }.to_json, headers: @headers
    end
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    assert_raises(ActionController::RoutingError) do
      put api_path("/#{note.truncated_id}"), params: { title: "x" }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      delete api_path("/#{note.truncated_id}"), headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      post api_path("/#{note.truncated_id}/confirm"), headers: @headers
    end
  end
end
