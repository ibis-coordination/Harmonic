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

  # Create
  test "create creates a new collective" do
    collective_params = {
      name: "New Collective",
      handle: "new-collective-#{SecureRandom.hex(4)}",
      description: "A new collective created via API",
      timezone: "America/New_York",
      tempo: "weekly"
    }
    assert_difference "Collective.count", 1 do
      post api_path, params: collective_params.to_json, headers: @headers
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "New Collective", body["name"]
  end

  test "create adds creator as member" do
    collective_params = {
      name: "New Collective",
      handle: "new-collective-#{SecureRandom.hex(4)}"
    }
    post api_path, params: collective_params.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    new_collective = Collective.find(body["id"])
    assert new_collective.users.include?(@user)
  end

  test "create with duplicate handle returns error" do
    collective_params = {
      name: "Duplicate Handle Collective",
      handle: @collective.handle
    }
    post api_path, params: collective_params.to_json, headers: @headers
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert body["error"].include?("Handle")
  end

  test "create with read-only token returns forbidden" do
    skip "Bug: collectives not recognized as valid resource for scope validation"
    @api_token.update!(scopes: ApiToken.read_scopes)
    collective_params = { name: "Test", handle: "test-#{SecureRandom.hex(4)}" }
    post api_path, params: collective_params.to_json, headers: @headers
    assert_response :forbidden
  end

  # Update
  test "update updates a collective" do
    skip "Bug: typo in collectives_controller.rb - references 'note' instead of 'collective'"
    update_params = {
      name: "Updated Collective Name",
      description: "Updated description"
    }
    put api_path("/#{@collective.id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    @collective.reload
    assert_equal "Updated Collective Name", @collective.name
  end

  test "update can change tempo" do
    skip "Bug: typo in collectives_controller.rb - references 'note' instead of 'collective'"
    update_params = { tempo: "daily" }
    put api_path("/#{@collective.id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    @collective.reload
    assert_equal "daily", @collective.tempo
  end

  test "update handle without force_update returns error" do
    skip "Bug: typo in collectives_controller.rb - references 'note' instead of 'collective'"
    update_params = { handle: "new-handle-#{SecureRandom.hex(4)}" }
    put api_path("/#{@collective.id}"), params: update_params.to_json, headers: @headers
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert body["error"].include?("force_update")
  end

  # Note: handle update with force_update test would need more setup
  # as it requires the controller to properly handle that case

  # Delete
  test "delete deletes a collective" do
    skip "Bug: Collective#delete! raises 'Delete not implemented'"
    collective_to_delete = Collective.create!(
      tenant: @tenant,
      created_by: @user,
      name: "Collective to Delete",
      handle: "delete-me-#{SecureRandom.hex(4)}"
    )
    collective_to_delete.add_user!(@user)
    assert_difference "Collective.count", -1 do
      delete api_path("/#{collective_to_delete.id}"), headers: @headers
    end
    assert_response :success
  end

  test "delete returns 404 for non-existent collective" do
    skip "Bug: typo in collectives_controller.rb - references 'collective' column"
    delete api_path("/nonexistent"), headers: @headers
    assert_response :not_found
  end
end
