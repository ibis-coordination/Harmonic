require "test_helper"
require "webmock/minitest"

class AskControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
    @base_url = ENV.fetch("LITELLM_BASE_URL", "http://litellm:4000")
  end

  # === Index (GET /ask) Tests ===

  test "unauthenticated user is redirected from ask page" do
    get "/ask"
    assert_response :redirect
  end

  test "authenticated user can access ask page" do
    sign_in_as(@user, tenant: @tenant)
    get "/ask"
    assert_response :success
    assert_select "h1", "Ask Harmonic"
    assert_select "form"
    assert_select "[data-controller='ask-chat']"
  end

  # === Create (POST /ask) HTML Tests ===

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
        }.to_json,
      )

    sign_in_as(@user, tenant: @tenant)
    post "/ask", params: { question: "How do I create a note?" }

    assert_response :success
    # HTML fallback still works (renders the index template)
    assert_select "h1", "Ask Harmonic"
  end

  test "HTML: submitting empty question shows alert" do
    sign_in_as(@user, tenant: @tenant)
    post "/ask", params: { question: "" }

    assert_response :success
  end

  test "HTML: unauthenticated user cannot submit question" do
    post "/ask", params: { question: "Test question" }
    assert_response :redirect
  end

  # === Create (POST /ask) JSON API Tests ===

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
        }.to_json,
      )

    sign_in_as(@user, tenant: @tenant)
    post "/ask",
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
    post "/ask",
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
    post "/ask",
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
    post "/ask",
      params: { question: "Test question" },
      headers: { "Accept" => "application/json" },
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_includes json["answer"], "Sorry, there was an error"
  end

  test "JSON: unauthenticated user cannot submit question" do
    post "/ask",
      params: { question: "Test question" },
      headers: { "Accept" => "application/json" },
      as: :json

    # JSON requests return 401 instead of redirect
    assert_response :unauthorized
  end
end
