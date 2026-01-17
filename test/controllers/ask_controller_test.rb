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
  end

  # === Create (POST /ask) Tests ===

  test "authenticated user can submit a question and receive an answer" do
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
    assert_select "h2", "Answer"
    assert_select ".answer", /To create a note/
  end

  test "question is preserved in form after submission" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Test answer" } }] }.to_json,
      )

    sign_in_as(@user, tenant: @tenant)
    post "/ask", params: { question: "My test question" }

    assert_response :success
    assert_select "textarea[name=question]", "My test question"
  end

  test "submitting empty question shows alert" do
    sign_in_as(@user, tenant: @tenant)
    post "/ask", params: { question: "" }

    assert_response :success
    # No answer section should be rendered
    assert_select "h2", { text: "Answer", count: 0 }
  end

  test "handles LLM service error gracefully" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(status: 500, body: "Internal Server Error")

    sign_in_as(@user, tenant: @tenant)
    post "/ask", params: { question: "Test question" }

    assert_response :success
    assert_select ".answer", /Sorry, there was an error connecting to the LLM service/
  end

  test "handles LLM service connection failure gracefully" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

    sign_in_as(@user, tenant: @tenant)
    post "/ask", params: { question: "Test question" }

    assert_response :success
    assert_select ".answer", /Sorry, there was an error connecting to the LLM service/
  end

  test "unauthenticated user cannot submit question" do
    post "/ask", params: { question: "Test question" }
    assert_response :redirect
  end
end
