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
    assert_includes result.error, "server error"
  end

  test "returns rate limit error message on 429" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(status: 429, body: '{"error": "rate limited"}')

    client = LLMClient.new
    result = client.chat(messages: [{ role: "user", content: "Test" }])

    assert_equal "", result.content
    assert_equal "error", result.finish_reason
    assert_includes result.error, "Rate limited"
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

  # === Stripe Gateway Mode ===

  test "defaults to litellm gateway mode" do
    client = LLMClient.new
    assert_equal :litellm, client.gateway_mode
  end

  test "uses stripe gateway mode from env" do
    ENV["LLM_GATEWAY_MODE"] = "stripe_gateway"
    # Must provide stripe_customer_id in stripe mode
    client = LLMClient.new(stripe_customer_id: "cus_test123")
    assert_equal :stripe_gateway, client.gateway_mode
  ensure
    ENV.delete("LLM_GATEWAY_MODE")
  end

  test "stripe mode raises ArgumentError when stripe_customer_id is nil" do
    assert_raises(ArgumentError) do
      LLMClient.new(gateway_mode: :stripe_gateway)
    end
  end

  test "stripe mode uses llm.stripe.com base URL" do
    ENV["STRIPE_GATEWAY_KEY"] = "sk_test_gateway"
    stripe_url = "https://llm.stripe.com/chat/completions"
    stub_request(:post, stripe_url)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(gateway_mode: :stripe_gateway, stripe_customer_id: "cus_test123")
    client.chat(messages: [{ role: "user", content: "Test" }])

    assert_requested :post, stripe_url
  ensure
    ENV.delete("STRIPE_GATEWAY_KEY")
  end

  test "stripe mode maps model via StripeModelMapper" do
    ENV["STRIPE_GATEWAY_KEY"] = "sk_test_gateway"
    stub_request(:post, "https://llm.stripe.com/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(gateway_mode: :stripe_gateway, stripe_customer_id: "cus_test123", model: "default")
    client.chat(messages: [{ role: "user", content: "Test" }])

    assert_requested :post, "https://llm.stripe.com/chat/completions" do |req|
      body = JSON.parse(req.body)
      body["model"] == "anthropic/claude-sonnet-4"
    end
  ensure
    ENV.delete("STRIPE_GATEWAY_KEY")
  end

  test "stripe mode sends Authorization Bearer with STRIPE_GATEWAY_KEY" do
    ENV["STRIPE_GATEWAY_KEY"] = "sk_test_gateway_key_123"
    stub_request(:post, "https://llm.stripe.com/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(gateway_mode: :stripe_gateway, stripe_customer_id: "cus_test123")
    client.chat(messages: [{ role: "user", content: "Test" }])

    assert_requested :post, "https://llm.stripe.com/chat/completions" do |req|
      req.headers["Authorization"] == "Bearer sk_test_gateway_key_123"
    end
  ensure
    ENV.delete("STRIPE_GATEWAY_KEY")
  end

  test "stripe mode sends X-Stripe-Customer-ID header" do
    ENV["STRIPE_GATEWAY_KEY"] = "sk_test_gateway"
    stub_request(:post, "https://llm.stripe.com/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(gateway_mode: :stripe_gateway, stripe_customer_id: "cus_abc789")
    client.chat(messages: [{ role: "user", content: "Test" }])

    assert_requested :post, "https://llm.stripe.com/chat/completions" do |req|
      req.headers["X-Stripe-Customer-Id"] == "cus_abc789"
    end
  ensure
    ENV.delete("STRIPE_GATEWAY_KEY")
  end

  test "stripe mode posts to /chat/completions (no /v1 prefix)" do
    ENV["STRIPE_GATEWAY_KEY"] = "sk_test_gateway"
    stub_request(:post, "https://llm.stripe.com/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(gateway_mode: :stripe_gateway, stripe_customer_id: "cus_test123")
    client.chat(messages: [{ role: "user", content: "Test" }])

    # Should NOT have been called with /v1/ prefix
    assert_not_requested :post, "https://llm.stripe.com/v1/chat/completions"
    assert_requested :post, "https://llm.stripe.com/chat/completions"
  ensure
    ENV.delete("STRIPE_GATEWAY_KEY")
  end

  test "litellm mode posts to /v1/chat/completions" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(gateway_mode: :litellm)
    client.chat(messages: [{ role: "user", content: "Test" }])

    assert_requested :post, "#{@base_url}/v1/chat/completions"
  end

  test "litellm mode does not send Authorization header" do
    stub_request(:post, "#{@base_url}/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { choices: [{ message: { content: "Response" } }] }.to_json,
      )

    client = LLMClient.new(gateway_mode: :litellm)
    client.chat(messages: [{ role: "user", content: "Test" }])

    assert_requested :post, "#{@base_url}/v1/chat/completions" do |req|
      req.headers["Authorization"].nil?
    end
  end

  test "handles 402 payment required in stripe mode" do
    ENV["STRIPE_GATEWAY_KEY"] = "sk_test_gateway"
    stub_request(:post, "https://llm.stripe.com/chat/completions")
      .to_return(status: 402, body: '{"error": "payment required"}')

    client = LLMClient.new(gateway_mode: :stripe_gateway, stripe_customer_id: "cus_test123")
    result = client.chat(messages: [{ role: "user", content: "Test" }])

    assert_equal "", result.content
    assert_equal "error", result.finish_reason
    assert_includes result.error, "Payment required"
  ensure
    ENV.delete("STRIPE_GATEWAY_KEY")
  end
end
