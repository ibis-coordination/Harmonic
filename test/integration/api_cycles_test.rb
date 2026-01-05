require "test_helper"

class ApiCyclesTest < ActionDispatch::IntegrationTest
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
    Studio.scope_thread_to_studio(subdomain: @tenant.subdomain, handle: @studio.handle)
  end

  def api_path(path = "")
    "#{@studio.path}/api/v1/cycles#{path}"
  end

  # Index
  test "index returns available cycles" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    cycle_names = body.map { |c| c["name"] }
    assert_includes cycle_names, "today"
    assert_includes cycle_names, "this-week"
    assert_includes cycle_names, "this-month"
    assert_includes cycle_names, "this-year"
  end

  test "index returns cycle metadata" do
    get api_path, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    today = body.find { |c| c["name"] == "today" }
    assert today.key?("display_name")
    assert today.key?("time_window")
    assert today.key?("unit")
    assert today.key?("start_date")
    assert today.key?("end_date")
    assert today.key?("counts")
  end

  test "index with include=notes returns notes" do
    create_note(tenant: @tenant, studio: @studio, created_by: @user)
    get api_path("?include=notes"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    today = body.find { |c| c["name"] == "today" }
    assert today.key?("notes")
  end

  test "index with include=decisions returns decisions" do
    create_decision(tenant: @tenant, studio: @studio, created_by: @user)
    get api_path("?include=decisions"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    today = body.find { |c| c["name"] == "today" }
    assert today.key?("decisions")
  end

  test "index with include=commitments returns commitments" do
    create_commitment(tenant: @tenant, studio: @studio, created_by: @user)
    get api_path("?include=commitments"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    today = body.find { |c| c["name"] == "today" }
    assert today.key?("commitments")
  end

  # Show
  test "show today returns today's content" do
    note = create_note(tenant: @tenant, studio: @studio, created_by: @user, title: "Today's Note")
    get api_path("/today"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "today", body["name"]
    assert body.key?("notes")
    assert body.key?("decisions")
    assert body.key?("commitments")
    assert body["notes"].any? { |n| n["title"] == "Today's Note" }
  end

  test "show this-week returns this week's content" do
    note = create_note(tenant: @tenant, studio: @studio, created_by: @user, title: "This Week's Note")
    get api_path("/this-week"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "this-week", body["name"]
    assert body["notes"].any? { |n| n["title"] == "This Week's Note" }
  end

  test "show this-month returns this month's content" do
    note = create_note(tenant: @tenant, studio: @studio, created_by: @user, title: "This Month's Note")
    get api_path("/this-month"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "this-month", body["name"]
    assert body["notes"].any? { |n| n["title"] == "This Month's Note" }
  end

  test "show this-year returns this year's content" do
    get api_path("/this-year"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "this-year", body["name"]
  end

  test "show yesterday returns yesterday's content" do
    get api_path("/yesterday"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "yesterday", body["name"]
  end

  test "show last-week returns last week's content" do
    get api_path("/last-week"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "last-week", body["name"]
  end

  test "show last-month returns last month's content" do
    get api_path("/last-month"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "last-month", body["name"]
  end

  # Cycles include content counts
  test "cycle counts include notes decisions and commitments" do
    create_note(tenant: @tenant, studio: @studio, created_by: @user)
    create_note(tenant: @tenant, studio: @studio, created_by: @user, title: "Second Note")
    create_decision(tenant: @tenant, studio: @studio, created_by: @user)
    create_commitment(tenant: @tenant, studio: @studio, created_by: @user)
    get api_path("/today"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body["notes"].length
    assert_equal 1, body["decisions"].length
    assert_equal 1, body["commitments"].length
  end

  # Create/Update/Destroy not supported
  test "create returns 404" do
    post api_path, params: { name: "custom" }.to_json, headers: @headers
    assert_response :not_found
  end

  test "update returns 404" do
    put api_path("/today"), params: { name: "modified" }.to_json, headers: @headers
    assert_response :not_found
  end

  test "destroy returns 404" do
    delete api_path("/today"), headers: @headers
    assert_response :not_found
  end
end
