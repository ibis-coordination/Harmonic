require "test_helper"
require "webmock/minitest"

class TrioClientTest < ActiveSupport::TestCase
  setup do
    @base_url = ENV.fetch("TRIO_BASE_URL", "http://trio:8000")
  end

  test "ask returns response content on success" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json",
          "X-Trio-Details" => { winner_index: 0, aggregation_method: "acceptance_voting", candidates: [] }.to_json,
        },
        body: {
          choices: [
            { message: { role: "assistant", content: "The answer is 4." } },
          ],
        }.to_json,
      )

    client = TrioClient.new
    response = client.ask("What is 2+2?")

    assert_equal "The answer is 4.", response
  end

  test "ask_with_details returns content and voting details" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json",
          "X-Trio-Details" => {
            winner_index: 1,
            aggregation_method: "acceptance_voting",
            candidates: [
              { "model" => "model1", "response" => "4", "accepted" => 2, "preferred" => 0 },
              { "model" => "model2", "response" => "The answer is 4.", "accepted" => 3, "preferred" => 2 },
            ],
          }.to_json,
        },
        body: {
          choices: [
            { message: { role: "assistant", content: "The answer is 4." } },
          ],
        }.to_json,
      )

    client = TrioClient.new
    result = client.ask_with_details("What is 2+2?")

    assert_equal "The answer is 4.", result.content
    assert_not_nil result.voting_details
    assert_equal 1, result.voting_details.winner_index
    assert_equal "acceptance_voting", result.voting_details.aggregation_method
    assert_equal 2, result.voting_details.candidates.length
    assert_equal "model2", result.voting_details.candidates[1]["model"]
  end

  test "ask sends correct request format" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = TrioClient.new
    client.ask("Test question")

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"].is_a?(Hash) &&
        body["model"]["ensemble"].is_a?(Array) &&
        body["model"]["ensemble"].all? { |m| m.is_a?(Hash) && m["model"].present? } &&
        body["model"]["aggregation_method"] == "acceptance_voting" &&
        body["messages"].is_a?(Array) &&
        body["messages"].length == 1 &&
        body["messages"][0]["role"] == "user" &&
        body["messages"][0]["content"] == "Test question" &&
        body["max_tokens"] == 2048
    end
  end

  test "ask with system prompt includes it in messages" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = TrioClient.new
    client.ask("Test question", system_prompt: "Be helpful and concise.")

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["messages"].length == 2 &&
        body["messages"][0]["role"] == "system" &&
        body["messages"][0]["content"] == "Be helpful and concise." &&
        body["messages"][1]["role"] == "user"
    end
  end

  test "ask_with_details sends ensemble in model config when specified" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = TrioClient.new
    ensemble = [
      { model: "llama3.2:1b", system_prompt: "Be concise" },
      { model: "mistral", system_prompt: "Be detailed" },
    ]
    client.ask_with_details("Test", ensemble: ensemble)

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"].is_a?(Hash) &&
        body["model"]["ensemble"].is_a?(Array) &&
        body["model"]["ensemble"].length == 2 &&
        body["model"]["ensemble"][0]["model"] == "llama3.2:1b" &&
        body["model"]["ensemble"][0]["system_prompt"] == "Be concise"
    end
  end

  test "ask_ensemble is shorthand for ask_with_details with ensemble" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = TrioClient.new
    ensemble = [{ model: "model1", system_prompt: "Prompt 1" }]
    result = client.ask_ensemble("Question", ensemble)

    assert_equal "Response", result.content

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"].is_a?(Hash) && body["model"]["ensemble"].present?
    end
  end

  test "returns fallback message when response has no content" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [] }.to_json,
      )

    client = TrioClient.new
    response = client.ask("Test question")

    assert_equal "Sorry, I couldn't generate a response.", response
  end

  test "returns error message on HTTP error" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(status: 500, body: "Internal Server Error")

    client = TrioClient.new
    response = client.ask("Test question")

    assert_equal "Sorry, there was an error connecting to the Trio service. Please try again later.", response
  end

  test "returns error message on connection failure" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

    client = TrioClient.new
    response = client.ask("Test question")

    assert_equal "Sorry, there was an error connecting to the Trio service. Please try again later.", response
  end

  test "returns error message on timeout" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_timeout

    client = TrioClient.new
    response = client.ask("Test question")

    assert_equal "Sorry, there was an error connecting to the Trio service. Please try again later.", response
  end

  test "handles missing X-Trio-Details header gracefully" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = TrioClient.new
    result = client.ask_with_details("Test")

    assert_equal "Response", result.content
    assert_nil result.voting_details
  end

  test "handles malformed X-Trio-Details header gracefully" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: {
          "Content-Type" => "application/json",
          "X-Trio-Details" => "not valid json",
        },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = TrioClient.new
    result = client.ask_with_details("Test")

    assert_equal "Response", result.content
    assert_nil result.voting_details
  end

  test "uses TRIO_BASE_URL env var" do
    ENV["TRIO_BASE_URL"] = "http://custom-trio:9000"

    stub_request(:post, "http://custom-trio:9000/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = TrioClient.new
    client.ask("Test")

    assert_requested :post, "http://custom-trio:9000/v1/chat/completions"
  ensure
    ENV["TRIO_BASE_URL"] = "http://trio:8000"
  end
end
