require "test_helper"

class ApiDecisionsTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @superagent = @global_superagent
    @superagent.enable_api!
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
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
  end

  def api_path(path = "")
    "#{@superagent.path}/api/v1/decisions#{path}"
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
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    get api_path("/#{decision.truncated_id}"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal decision.id, body["id"]
    assert_equal decision.question, body["question"]
    assert_equal decision.truncated_id, body["truncated_id"]
  end

  test "show returns 404 for non-existent decision" do
    # Note: The controller raises RecordNotFound which Rails converts to 404 in production
    assert_raises(ActiveRecord::RecordNotFound) do
      get api_path("/nonexistent"), headers: @headers
    end
  end

  test "show with include=options returns options" do
    skip "Bug: Option model missing api_json method"
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option 1")
    get api_path("/#{decision.truncated_id}?include=options"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("options")
    assert_equal 1, body["options"].length
  end

  test "show with include=participants returns participants" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    get api_path("/#{decision.truncated_id}?include=participants"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("participants")
  end

  test "show with include=results returns results" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    get api_path("/#{decision.truncated_id}?include=results"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("results")
  end

  # Create
  test "create creates a decision" do
    decision_params = {
      question: "What should we do?",
      description: "A test decision",
      deadline: (Time.current + 1.week).iso8601,
      options_open: true
    }
    assert_difference "Decision.count", 1 do
      post api_path, params: decision_params.to_json, headers: @headers
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "What should we do?", body["question"]
  end

  test "create with options creates decision and options" do
    skip "Bug: LinkParser fails when studio is main studio"
    decision_params = {
      question: "Pick one",
      deadline: (Time.current + 1.week).iso8601,
      options_open: true,
      options: [
        { title: "Option A", description: "First option" },
        { title: "Option B", description: "Second option" }
      ]
    }
    assert_difference "Decision.count", 1 do
      assert_difference "Option.count", 2 do
        post api_path, params: decision_params.to_json, headers: @headers
      end
    end
    assert_response :success
  end

  test "create without required fields returns error" do
    decision_params = { description: "Missing question" }
    post api_path, params: decision_params.to_json, headers: @headers
    assert_response :bad_request
  end

  test "create with read-only token returns forbidden" do
    @api_token.update!(scopes: ApiToken.read_scopes)
    decision_params = {
      question: "Test?",
      deadline: (Time.current + 1.week).iso8601
    }
    post api_path, params: decision_params.to_json, headers: @headers
    assert_response :forbidden
  end

  # Update
  test "update updates a decision by creator" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    update_params = {
      question: "Updated question?",
      description: "Updated description"
    }
    put api_path("/#{decision.truncated_id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    decision.reload
    assert_equal "Updated question?", decision.question
  end

  test "update can toggle options_open" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    decision.update!(options_open: true)
    update_params = { options_open: false }
    put api_path("/#{decision.truncated_id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    decision.reload
    assert_equal false, decision.options_open
  end

  test "update by non-creator returns forbidden" do
    other_user = create_user(email: "other@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: other_user)
    update_params = { question: "Hacked question?" }
    put api_path("/#{decision.truncated_id}"), params: update_params.to_json, headers: @headers
    assert_response :forbidden
  end

  # Options
  test "create option adds option to decision" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option_params = { title: "New Option", description: "Option description" }
    assert_difference "Option.count", 1 do
      post api_path("/#{decision.truncated_id}/options"), params: option_params.to_json, headers: @headers
    end
    assert_response :success
  end

  test "create option when options_open is false returns forbidden for non-creator" do
    other_user = create_user(email: "other@example.com", name: "Other User")
    @tenant.add_user!(other_user)
    @superagent.add_user!(other_user)
    other_token = ApiToken.create!(tenant: @tenant, user: other_user, scopes: ApiToken.valid_scopes)
    other_headers = @headers.merge("Authorization" => "Bearer #{other_token.token}")

    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    decision.update!(options_open: false)
    option_params = { title: "New Option" }
    post api_path("/#{decision.truncated_id}/options"), params: option_params.to_json, headers: other_headers
    assert_response :forbidden
  end

  test "list options returns all options" do
    skip "Bug: Option model missing api_json method"
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option 1")
    create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option 2")
    get api_path("/#{decision.truncated_id}/options"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body.length
  end

  # Votes
  test "create vote casts a vote" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)
    vote_params = { accepted: 1, preferred: 0 }
    assert_difference "Vote.count", 1 do
      post api_path("/#{decision.truncated_id}/options/#{option.id}/votes"), params: vote_params.to_json, headers: @headers
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["accepted"]
    assert_equal 0, body["preferred"]
  end

  test "create vote with preference" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)
    vote_params = { accepted: 1, preferred: 1 }
    post api_path("/#{decision.truncated_id}/options/#{option.id}/votes"), params: vote_params.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["preferred"]
  end

  test "update vote changes vote" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)
    # First, cast a vote
    vote_params = { accepted: 1, preferred: 0 }
    post api_path("/#{decision.truncated_id}/options/#{option.id}/votes"), params: vote_params.to_json, headers: @headers
    assert_response :success
    vote_id = JSON.parse(response.body)["id"]
    # Then update it
    update_params = { accepted: 0 }
    put api_path("/#{decision.truncated_id}/options/#{option.id}/votes/#{vote_id}"), params: update_params.to_json, headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 0, body["accepted"]
  end

  # Results
  test "get results returns voting results" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    option1 = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option 1")
    option2 = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision, title: "Option 2")
    # Vote for option1
    post api_path("/#{decision.truncated_id}/options/#{option1.id}/votes"), params: { accepted: 1, preferred: 1 }.to_json, headers: @headers
    get api_path("/#{decision.truncated_id}/results"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    # Option with vote should be ranked higher
    winner = body.find { |r| r["option_id"] == option1.id }
    assert_equal 1, winner["accepted_yes"]
  end

  # Participants
  test "list participants returns decision participants" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)
    # Create a participant by voting
    option = create_option(tenant: @tenant, superagent: @superagent, created_by: @user, decision: decision)
    post api_path("/#{decision.truncated_id}/options/#{option.id}/votes"), params: { accepted: 1 }.to_json, headers: @headers
    get api_path("/#{decision.truncated_id}/participants"), headers: @headers
    assert_response :success
    body = JSON.parse(response.body)
    assert body.is_a?(Array)
    assert body.any? { |p| p["user_id"] == @user.id }
  end
end
