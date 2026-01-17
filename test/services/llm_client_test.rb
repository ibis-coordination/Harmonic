require "test_helper"
require "webmock/minitest"

class LlmClientTest < ActiveSupport::TestCase
  setup do
    @base_url = ENV.fetch("LITELLM_BASE_URL", "http://litellm:4000")
  end

  test "ask returns LLM response content on success" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          choices: [
            {
              message: {
                role: "assistant",
                content: "To create a note in Harmonic, navigate to your studio and click the 'New Note' button.",
              },
            },
          ],
        }.to_json,
      )

    client = LlmClient.new
    response = client.ask("How do I create a note?")

    assert_equal "To create a note in Harmonic, navigate to your studio and click the 'New Note' button.", response
  end

  test "ask sends correct request format" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .with(
        headers: { "Content-Type" => "application/json" },
      )
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Test response" } }] }.to_json,
      )

    client = LlmClient.new
    client.ask("Test question")

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"] == "default" &&
        body["messages"].is_a?(Array) &&
        body["messages"].length == 2 &&
        body["messages"][0]["role"] == "system" &&
        body["messages"][1]["role"] == "user" &&
        body["messages"][1]["content"] == "Test question" &&
        body["max_tokens"] == 2048
    end
  end

  test "ask returns fallback message when response has no content" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [] }.to_json,
      )

    client = LlmClient.new
    response = client.ask("Test question")

    assert_equal "Sorry, I couldn't generate a response.", response
  end

  test "ask returns error message on HTTP error" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(status: 500, body: "Internal Server Error")

    client = LlmClient.new
    response = client.ask("Test question")

    assert_equal "Sorry, there was an error connecting to the LLM service. Please try again later.", response
  end

  test "ask returns error message on connection failure" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

    client = LlmClient.new
    response = client.ask("Test question")

    assert_equal "Sorry, there was an error connecting to the LLM service. Please try again later.", response
  end

  test "ask returns error message on timeout" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_timeout

    client = LlmClient.new
    response = client.ask("Test question")

    assert_equal "Sorry, there was an error connecting to the LLM service. Please try again later.", response
  end

  test "ask returns error message on invalid JSON response" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: "not valid json",
      )

    client = LlmClient.new
    response = client.ask("Test question")

    assert_equal "Sorry, there was an error connecting to the LLM service. Please try again later.", response
  end

  test "uses CHAT_MODEL env var for model selection" do
    ENV["CHAT_MODEL"] = "claude"

    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response from Claude" } }] }.to_json,
      )

    client = LlmClient.new
    client.ask("Test question")

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"] == "claude"
    end
  ensure
    ENV["CHAT_MODEL"] = "default"
  end

  test "system prompt includes Harmonic context" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Test" } }] }.to_json,
      )

    client = LlmClient.new
    client.ask("Test question")

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      system_message = body["messages"][0]
      system_message["role"] == "system" &&
        system_message["content"].include?("helpful assistant for Harmonic")
    end
  end

  test "ask strips thinking tags from response" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          choices: [
            {
              message: {
                role: "assistant",
                content: "<thinking>\nThe user is asking about notes.\nLet me explain how to create one.\n</thinking>\nTo create a note, click the 'New Note' button.",
              },
            },
          ],
        }.to_json,
      )

    client = LlmClient.new
    response = client.ask("How do I create a note?")

    assert_equal "To create a note, click the 'New Note' button.", response
    assert_not_includes response, "<thinking>"
    assert_not_includes response, "</thinking>"
  end

  test "ask handles response with no thinking tags" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          choices: [
            {
              message: {
                role: "assistant",
                content: "This is a simple response without thinking tags.",
              },
            },
          ],
        }.to_json,
      )

    client = LlmClient.new
    response = client.ask("Simple question")

    assert_equal "This is a simple response without thinking tags.", response
  end
end
