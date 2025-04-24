require "test_helper"

class ApiTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @studio = @global_studio
    @studio.enable_api!
    @user = @global_user
    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @headers = {
      "Authorization" => "Bearer #{@api_token.token}",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def v1_api_base_path
    "#{@studio.path}/api/v1"
  end

  def v1_api_endpoint
    "#{v1_api_base_path}/cycles"
  end

  test "allows access with valid API token" do
    get v1_api_endpoint, headers: @headers
    assert_response :success
  end

  test "denies access with invalid API token" do
    @headers["Authorization"] = "Bearer invalid_token"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access without API token" do
    @headers.delete("Authorization")
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access with expired API token" do
    @api_token.update!(expires_at: Time.current - 1.day)
    @headers["Authorization"] = "Bearer #{@api_token.token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "denies access with deleted API token" do
    @api_token.update!(deleted_at: Time.current)
    @headers["Authorization"] = "Bearer #{@api_token.token}"
    get v1_api_endpoint, headers: @headers
    assert_response :unauthorized
  end

  test "allows write access with write scope" do
    @api_token.update!(scopes: ApiToken.valid_scopes)
    @headers["Authorization"] = "Bearer #{@api_token.token}"
    note_params = {
      title: "Test Note",
      text: "This is a test note.",
      deadline: Time.current + 1.week
    }
    post "#{v1_api_base_path}/notes", params: note_params.to_json, headers: @headers
    assert_response :success
    assert_equal "Test Note", JSON.parse(response.body)["title"]
  end

  test "denies write access with read-only scope" do
    @api_token.update!(scopes: ApiToken.read_scopes)
    @headers["Authorization"] = "Bearer #{@api_token.token}"
    note_params = {
      title: "Test Note",
      text: "This is a test note.",
      deadline: Time.current + 1.week
    }
    post "#{v1_api_base_path}/notes", params: note_params.to_json, headers: @headers
    assert_response :forbidden
  end
end