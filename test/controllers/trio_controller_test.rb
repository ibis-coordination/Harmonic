require "test_helper"
require "webmock/minitest"

class TrioControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}"
    @base_url = ENV.fetch("TRIO_BASE_URL", "http://trio:8000")
    # Enable trio feature flag for tests
    @tenant.set_feature_flag!("trio", true)
  end

  # === Index (GET /trio) Tests ===

  test "unauthenticated user is redirected from trio page" do
    get "/trio"
    assert_response :redirect
  end

  test "authenticated user can access trio page" do
    sign_in_as(@user, tenant: @tenant)
    get "/trio"
    assert_response :success
    # Trio is now a "Coming Soon" placeholder page
    assert_select ".trio-coming-soon"
    assert_select ".trio-coming-soon-text", "Coming Soon"
    assert_select "[data-controller='trio-logo']"
  end

  # === Create (POST /trio) HTML Tests ===

  test "HTML: authenticated user can submit a question and receive an answer" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          choices: [
            {
              message: {
                role: "assistant",
                content: "To create a note, click the 'New Note' button in your studio.",
              },
            },
          ],
        }.to_json
      )

    sign_in_as(@user, tenant: @tenant)
    post "/trio", params: { question: "How do I create a note?" }

    assert_response :success
    # HTML fallback still works (renders the index template - now "Coming Soon" placeholder)
    assert_select ".trio-coming-soon"
  end

  test "HTML: submitting empty question shows alert" do
    sign_in_as(@user, tenant: @tenant)
    post "/trio", params: { question: "" }

    assert_response :success
  end

  test "HTML: unauthenticated user cannot submit question" do
    post "/trio", params: { question: "Test question" }
    assert_response :redirect
  end

  # === Create (POST /trio) JSON API Tests ===

  test "JSON: returns success with question and answer" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          choices: [
            {
              message: {
                role: "assistant",
                content: "To create a note, click the 'New Note' button in your studio.",
              },
            },
          ],
        }.to_json
      )

    sign_in_as(@user, tenant: @tenant)
    post "/trio",
         params: { question: "How do I create a note?" },
         headers: { "Accept" => "application/json" },
         as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "How do I create a note?", json["question"]
    assert_includes json["answer"], "To create a note"
  end

  test "JSON: returns error for empty question" do
    sign_in_as(@user, tenant: @tenant)
    post "/trio",
         params: { question: "" },
         headers: { "Accept" => "application/json" },
         as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
    assert_equal "Please enter a question.", json["error"]
  end

  test "JSON: handles LLM service error gracefully" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(status: 500, body: "Internal Server Error")

    sign_in_as(@user, tenant: @tenant)
    post "/trio",
         params: { question: "Test question" },
         headers: { "Accept" => "application/json" },
         as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_includes json["answer"], "Sorry, there was an error"
  end

  test "JSON: handles LLM connection failure gracefully" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

    sign_in_as(@user, tenant: @tenant)
    post "/trio",
         params: { question: "Test question" },
         headers: { "Accept" => "application/json" },
         as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_includes json["answer"], "Sorry, there was an error"
  end

  test "JSON: unauthenticated user cannot submit question" do
    post "/trio",
         params: { question: "Test question" },
         headers: { "Accept" => "application/json" },
         as: :json

    # JSON requests return 401 instead of redirect
    assert_response :unauthorized
  end

  # === Aggregation Method Tests ===

  test "JSON: accepts aggregation_method parameter" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json",
          "X-Trio-Details" => { winner_index: 0, aggregation_method: "random", candidates: [] }.to_json,
        },
        body: { choices: [{ message: { content: "Response" } }] }.to_json
      )

    sign_in_as(@user, tenant: @tenant)
    post "/trio",
         params: { question: "Test", aggregation_method: "random" },
         headers: { "Accept" => "application/json" },
         as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "random", json["aggregation_method"]

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"]["aggregation_method"] == "random"
    end
  end

  test "JSON: accepts judge_model parameter when using judge aggregation" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json",
          "X-Trio-Details" => { winner_index: 0, aggregation_method: "judge", candidates: [] }.to_json,
        },
        body: { choices: [{ message: { content: "Response" } }] }.to_json
      )

    sign_in_as(@user, tenant: @tenant)
    post "/trio",
         params: { question: "Test", aggregation_method: "judge", judge_model: "claude-sonnet-4" },
         headers: { "Accept" => "application/json" },
         as: :json

    assert_response :success

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"]["aggregation_method"] == "judge" &&
        body["model"]["judge_model"] == "claude-sonnet-4"
    end
  end

  test "JSON: accepts synthesize_model parameter when using synthesize aggregation" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json",
          "X-Trio-Details" => { winner_index: 0, aggregation_method: "synthesize", candidates: [] }.to_json,
        },
        body: { choices: [{ message: { content: "Response" } }] }.to_json
      )

    sign_in_as(@user, tenant: @tenant)
    post "/trio",
         params: { question: "Test", aggregation_method: "synthesize", synthesize_model: "claude-sonnet-4" },
         headers: { "Accept" => "application/json" },
         as: :json

    assert_response :success

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"]["aggregation_method"] == "synthesize" &&
        body["model"]["synthesize_model"] == "claude-sonnet-4"
    end
  end

  # === Feature Flag Tests ===

  test "HTML: returns 403 when trio is disabled for tenant" do
    @tenant.set_feature_flag!("trio", false)
    sign_in_as(@user, tenant: @tenant)

    get "/trio"

    assert_response :forbidden
  end

  test "JSON: returns 403 when trio is disabled for tenant" do
    @tenant.set_feature_flag!("trio", false)
    sign_in_as(@user, tenant: @tenant)

    get "/trio",
        headers: { "Accept" => "application/json" },
        as: :json

    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Trio AI is not enabled for this tenant", json["error"]
  end

  test "POST HTML: returns 403 when trio is disabled for tenant" do
    @tenant.set_feature_flag!("trio", false)
    sign_in_as(@user, tenant: @tenant)

    post "/trio", params: { question: "Test question" }

    assert_response :forbidden
  end

  test "POST JSON: returns 403 when trio is disabled for tenant" do
    @tenant.set_feature_flag!("trio", false)
    sign_in_as(@user, tenant: @tenant)

    post "/trio",
         params: { question: "Test question" },
         headers: { "Accept" => "application/json" },
         as: :json

    assert_response :forbidden
    json = JSON.parse(response.body)
    assert_equal "Trio AI is not enabled for this tenant", json["error"]
  end
end
