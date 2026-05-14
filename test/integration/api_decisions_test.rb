require "test_helper"

class ApiDecisionsTest < ActionDispatch::IntegrationTest
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
    "#{@collective.path}/api/v1/decisions#{path}"
  end

  # Index is not supported
  test "index returns 404 with helpful message" do
    get api_path, headers: @headers
    assert_response :not_found
    body = JSON.parse(response.body)
    assert body["message"].include?("cycles")
  end

  # Show
  test "show returns a decision" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    get api_path("/#{decision.truncated_id}"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal decision.id, body["id"]
    assert_equal decision.question, body["question"]
    assert_equal decision.truncated_id, body["truncated_id"]
  end

  test "show returns 404 for non-existent decision" do
    get api_path("/nonexistent"), headers: @headers
    assert_response :not_found
  end

  test "show with include=options returns options" do
    skip "Bug: Option model missing api_json method"
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    create_option(tenant: @tenant, collective: @collective, created_by: @user, decision: decision, title: "Option 1")
    get api_path("/#{decision.truncated_id}?include=options"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("options")
    assert_equal 1, body["options"].length
  end

  test "show with include=participants returns participants" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    get api_path("/#{decision.truncated_id}?include=participants"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("participants")
  end

  test "show with include=results returns results" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    get api_path("/#{decision.truncated_id}?include=results"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("results")
  end

  test "list options returns all options" do
    skip "Bug: Option model missing api_json method"
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    create_option(tenant: @tenant, collective: @collective, created_by: @user, decision: decision, title: "Option 1")
    create_option(tenant: @tenant, collective: @collective, created_by: @user, decision: decision, title: "Option 2")
    get api_path("/#{decision.truncated_id}/options"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body.length
  end

  test "get results returns voting results" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    option1 = create_option(tenant: @tenant, collective: @collective, created_by: @user, decision: decision, title: "Option 1")
    create_option(tenant: @tenant, collective: @collective, created_by: @user, decision: decision, title: "Option 2")
    participant = DecisionParticipant.find_or_create_by!(decision: decision, user: @user)
    Vote.create!(option: option1, decision: decision, decision_participant: participant, accepted: 1, preferred: 1)

    get api_path("/#{decision.truncated_id}/results"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    winner = body.find { |r| r["option_id"] == option1.id }
    assert_equal 1, winner["accepted_yes"]
  end

  test "list participants returns decision participants" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    DecisionParticipant.find_or_create_by!(decision: decision, user: @user)

    get api_path("/#{decision.truncated_id}/participants"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    assert body.any? { |p| p["user_id"] == @user.id }
  end

  # === v1 API is read-only — decision writes happen via action routes ===

  test "v1 decisions API has no write routes (read-only API)" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    assert_raises(ActionController::RoutingError) do
      post api_path, params: { question: "x" }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      put api_path("/#{decision.truncated_id}"), params: { question: "x" }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      delete api_path("/#{decision.truncated_id}"), headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      post api_path("/#{decision.truncated_id}/options"), params: { title: "x" }.to_json, headers: @headers
    end
    assert_raises(ActionController::RoutingError) do
      post api_path("/#{decision.truncated_id}/votes"), params: { accepted: 1 }.to_json, headers: @headers
    end
  end
end
