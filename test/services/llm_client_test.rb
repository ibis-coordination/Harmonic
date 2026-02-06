require "test_helper"
require "webmock/minitest"

class LLMClientTest < ActiveSupport::TestCase
  setup do
    @base_url = ENV.fetch("LLM_BASE_URL", "http://litellm:4000")
  end

  # === Basic functionality ===

  test "chat returns response content on success" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          choices: [
            { message: { role: "assistant", content: "The answer is 4." }, finish_reason: "stop" },
          ],
          model: "gpt-4",
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
        }.to_json,
      )

    client = LLMClient.new
    result = client.chat(messages: [{ role: "user", content: "What is 2+2?" }])

    assert_equal "The answer is 4.", result.content
    assert_equal "gpt-4", result.model
    assert_equal "stop", result.finish_reason
    assert_equal 15, result.usage["total_tokens"]
  end

  test "ask is shorthand for chat with single user message" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "42" } }] }.to_json,
      )

    client = LLMClient.new
    response = client.ask("What is the meaning of life?")

    assert_equal "42", response
  end

  # === Request format ===

  test "chat sends correct request format" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new
    client.chat(messages: [{ role: "user", content: "Test question" }])

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"] == "default" &&
        body["messages"].is_a?(Array) &&
        body["messages"].length == 1 &&
        body["messages"][0]["role"] == "user" &&
        body["messages"][0]["content"] == "Test question" &&
        body["max_tokens"] == 4096 &&
        body["temperature"] == 0.7
    end
  end

  test "chat with system prompt prepends it to messages" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new
    client.chat(
      messages: [{ role: "user", content: "Test question" }],
      system_prompt: "Be helpful and concise."
    )

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["messages"].length == 2 &&
        body["messages"][0]["role"] == "system" &&
        body["messages"][0]["content"] == "Be helpful and concise." &&
        body["messages"][1]["role"] == "user"
    end
  end

  test "ask with system prompt works correctly" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new
    client.ask("Question", system_prompt: "Be brief")

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["messages"][0]["role"] == "system" &&
        body["messages"][0]["content"] == "Be brief"
    end
  end

  # === Configuration ===

  test "uses custom model" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(model: "claude-3-opus")
    client.ask("Test")

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"] == "claude-3-opus"
    end
  end

  test "uses custom temperature and max_tokens" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(temperature: 0.9, max_tokens: 500)
    client.ask("Test")

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["temperature"] == 0.9 && body["max_tokens"] == 500
    end
  end

  test "chat can override instance defaults" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(temperature: 0.5, max_tokens: 1000)
    client.chat(
      messages: [{ role: "user", content: "Test" }],
      temperature: 0.9,
      max_tokens: 500
    )

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["temperature"] == 0.9 && body["max_tokens"] == 500
    end
  end

  test "uses LLM_BASE_URL env var" do
    ENV["LLM_BASE_URL"] = "http://custom-llm:9000"

    stub_request(:post, "http://custom-llm:9000/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new
    client.ask("Test")

    assert_requested :post, "http://custom-llm:9000/v1/chat/completions"
  ensure
    ENV["LLM_BASE_URL"] = "http://litellm:4000"
  end

  test "uses LLM_MODEL env var" do
    ENV["LLM_MODEL"] = "custom-model"

    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new
    client.ask("Test")

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"] == "custom-model"
    end
  ensure
    ENV.delete("LLM_MODEL")
  end

  # === Error handling ===

  test "returns empty content when response has no choices" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [] }.to_json,
      )

    client = LLMClient.new
    result = client.chat(messages: [{ role: "user", content: "Test" }])

    assert_equal "", result.content
  end

  test "returns error message on HTTP error" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(status: 500, body: "Internal Server Error")

    client = LLMClient.new
    result = client.chat(messages: [{ role: "user", content: "Test" }])

    assert_equal "", result.content
    assert_equal "error", result.finish_reason
    assert_includes result.error, "JSON parse error" # 500 response body isn't valid JSON
  end

  test "returns error message on connection failure" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

    client = LLMClient.new
    result = client.chat(messages: [{ role: "user", content: "Test" }])

    assert_equal "", result.content
    assert_equal "error", result.finish_reason
    assert_includes result.error, "Connection refused"
  end

  test "returns error message on timeout" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_timeout

    client = LLMClient.new
    result = client.chat(messages: [{ role: "user", content: "Test" }])

    assert_equal "", result.content
    assert_equal "error", result.finish_reason
    assert_includes result.error, "Connection error"
  end

  test "returns error message on JSON parse error" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: "not valid json",
      )

    client = LLMClient.new
    result = client.chat(messages: [{ role: "user", content: "Test" }])

    assert_equal "", result.content
    assert_equal "error", result.finish_reason
    assert_includes result.error, "JSON parse error"
  end

  # === Multi-turn conversations ===

  test "chat supports multi-turn conversations" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Hello again!" } }] }.to_json,
      )

    client = LLMClient.new
    client.chat(messages: [
      { role: "user", content: "Hello" },
      { role: "assistant", content: "Hi there!" },
      { role: "user", content: "How are you?" },
    ])

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["messages"].length == 3 &&
        body["messages"][0]["role"] == "user" &&
        body["messages"][1]["role"] == "assistant" &&
        body["messages"][2]["role"] == "user"
    end
  end
end
