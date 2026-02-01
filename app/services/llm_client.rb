# typed: strict
# frozen_string_literal: true

# General-purpose client for LLM APIs (OpenAI-compatible).
# Uses LiteLLM as the backend to support multiple providers (Anthropic, OpenAI, Ollama, etc.).
#
# This is a simpler alternative to TrioClient for cases where you just need
# to call an LLM without the voting ensemble logic.
#
# @example Basic usage
#   client = LLMClient.new
#   response = client.chat(messages: [{ role: "user", content: "Hello!" }])
#   puts response.content
#
# @example With system prompt
#   client = LLMClient.new(model: "claude-3-sonnet")
#   response = client.chat(
#     messages: [{ role: "user", content: "Explain Ruby blocks" }],
#     system_prompt: "You are a helpful programming tutor."
#   )
#
# @example With custom configuration
#   client = LLMClient.new(
#     model: "gpt-4",
#     temperature: 0.7,
#     max_tokens: 1000
#   )
#
class LLMClient
  extend T::Sig

  # Result structure for chat completions
  class Result < T::Struct
    const :content, String
    const :model, T.nilable(String)
    const :usage, T.nilable(T::Hash[String, T.untyped])
    const :finish_reason, T.nilable(String)
  end

  # Default configuration
  DEFAULT_BASE_URL = "http://litellm:4000"
  DEFAULT_MODEL = "default"
  DEFAULT_MAX_TOKENS = 2048
  DEFAULT_TEMPERATURE = 0.7
  DEFAULT_TIMEOUT = 120

  sig do
    params(
      model: T.nilable(String),
      base_url: T.nilable(String),
      temperature: T.nilable(Float),
      max_tokens: T.nilable(Integer),
      timeout: T.nilable(Integer)
    ).void
  end
  def initialize(model: nil, base_url: nil, temperature: nil, max_tokens: nil, timeout: nil)
    @model = T.let(model || ENV.fetch("LLM_MODEL", DEFAULT_MODEL), String)
    @base_url = T.let(base_url || ENV.fetch("LLM_BASE_URL", DEFAULT_BASE_URL), String)
    @temperature = T.let(temperature || ENV.fetch("LLM_TEMPERATURE", DEFAULT_TEMPERATURE.to_s).to_f, Float)
    @max_tokens = T.let(max_tokens || ENV.fetch("LLM_MAX_TOKENS", DEFAULT_MAX_TOKENS.to_s).to_i, Integer)
    @timeout = T.let(timeout || ENV.fetch("LLM_TIMEOUT", DEFAULT_TIMEOUT.to_s).to_i, Integer)
  end

  # Send a chat completion request to the LLM.
  #
  # @param messages [Array<Hash>] Array of message hashes with :role and :content keys
  # @param system_prompt [String, nil] Optional system prompt to prepend to messages
  # @param max_tokens [Integer, nil] Override default max_tokens for this request
  # @param temperature [Float, nil] Override default temperature for this request
  # @return [Result] The completion result
  #
  # @example
  #   result = client.chat(
  #     messages: [{ role: "user", content: "What is 2+2?" }],
  #     system_prompt: "Be concise."
  #   )
  #   puts result.content  # => "4"
  sig do
    params(
      messages: T::Array[T::Hash[Symbol, String]],
      system_prompt: T.nilable(String),
      max_tokens: T.nilable(Integer),
      temperature: T.nilable(Float)
    ).returns(Result)
  end
  def chat(messages:, system_prompt: nil, max_tokens: nil, temperature: nil)
    full_messages = build_messages(messages, system_prompt)
    body = build_request_body(full_messages, max_tokens, temperature)

    response = make_request(body)
    parse_response(response)
  rescue Faraday::Error => e
    Rails.logger.error("LLMClient connection error: #{e.message}")
    error_result("Sorry, there was an error connecting to the LLM service. Please try again later.")
  rescue JSON::ParserError => e
    Rails.logger.error("LLMClient parse error: #{e.message}")
    error_result("Sorry, there was an error parsing the LLM response.")
  rescue StandardError => e
    Rails.logger.error("LLMClient error: #{e.class} - #{e.message}")
    error_result("Sorry, an unexpected error occurred.")
  end

  # Simple ask interface - just provide a question and get an answer.
  #
  # @param question [String] The question to ask
  # @param system_prompt [String, nil] Optional system prompt
  # @return [String] The response content
  sig { params(question: String, system_prompt: T.nilable(String)).returns(String) }
  def ask(question, system_prompt: nil)
    chat(
      messages: [{ role: "user", content: question }],
      system_prompt: system_prompt
    ).content
  end

  private

  sig do
    params(
      messages: T::Array[T::Hash[Symbol, String]],
      system_prompt: T.nilable(String)
    ).returns(T::Array[T::Hash[Symbol, String]])
  end
  def build_messages(messages, system_prompt)
    result = T.let([], T::Array[T::Hash[Symbol, String]])
    result << { role: "system", content: system_prompt } if system_prompt.present?
    result.concat(messages)
    result
  end

  sig do
    params(
      messages: T::Array[T::Hash[Symbol, String]],
      max_tokens: T.nilable(Integer),
      temperature: T.nilable(Float)
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def build_request_body(messages, max_tokens, temperature)
    {
      model: @model,
      messages: messages,
      max_tokens: max_tokens || @max_tokens,
      temperature: temperature || @temperature,
    }
  end

  sig { params(body: T::Hash[Symbol, T.untyped]).returns(Faraday::Response) }
  def make_request(body)
    connection.post("/v1/chat/completions") do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = body.to_json
    end
  end

  sig { params(response: Faraday::Response).returns(Result) }
  def parse_response(response)
    parsed = T.cast(JSON.parse(response.body), T::Hash[String, T.untyped])

    content = T.cast(
      parsed.dig("choices", 0, "message", "content"),
      T.nilable(String)
    ) || ""

    finish_reason = T.cast(
      parsed.dig("choices", 0, "finish_reason"),
      T.nilable(String)
    )

    usage = T.cast(parsed["usage"], T.nilable(T::Hash[String, T.untyped]))
    model = T.cast(parsed["model"], T.nilable(String))

    Result.new(
      content: content.strip,
      model: model,
      usage: usage,
      finish_reason: finish_reason
    )
  end

  sig { params(message: String).returns(Result) }
  def error_result(message)
    Result.new(
      content: message,
      model: nil,
      usage: nil,
      finish_reason: "error"
    )
  end

  sig { returns(Faraday::Connection) }
  def connection
    @connection ||= T.let(
      Faraday.new(url: @base_url) do |f|
        f.options.timeout = @timeout
        f.options.open_timeout = 10
      end,
      T.nilable(Faraday::Connection)
    )
  end
end
