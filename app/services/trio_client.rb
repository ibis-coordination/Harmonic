# typed: strict
# frozen_string_literal: true

# Client for Trio voting ensemble service.
# Trio is an OpenAI-compatible API that queries multiple LLM models,
# runs acceptance voting to select the best response, and returns it.
class TrioClient
  extend T::Sig

  # Voting details returned from Trio
  class VotingDetails < T::Struct
    const :winner_index, Integer
    const :candidates, T::Array[T::Hash[String, T.untyped]]
  end

  # Result with both response and voting metadata
  class Result < T::Struct
    const :content, String
    const :voting_details, T.nilable(VotingDetails)
  end

  sig { void }
  def initialize
    @base_url = T.let(ENV.fetch("TRIO_BASE_URL", "http://trio:8000"), String)
    @timeout = T.let(ENV.fetch("TRIO_TIMEOUT", "120").to_i, Integer)
  end

  # Simple ask - returns just the response content
  sig { params(question: String, system_prompt: T.nilable(String)).returns(String) }
  def ask(question, system_prompt: nil)
    ask_with_details(question, system_prompt: system_prompt).content
  end

  # Ask with full voting details
  sig do
    params(
      question: String,
      system_prompt: T.nilable(String),
      ensemble: T.nilable(T::Array[T::Hash[Symbol, String]]),
    ).returns(Result)
  end
  def ask_with_details(question, system_prompt: nil, ensemble: nil)
    messages = build_messages(question, system_prompt)
    body = build_request_body(messages, ensemble)

    response = make_request(body)
    parse_response(response)
  rescue Faraday::Error, JSON::ParserError => e
    Rails.logger.error("TrioClient error: #{e.message}")
    Result.new(
      content: "Sorry, there was an error connecting to the Trio service. Please try again later.",
      voting_details: nil,
    )
  end

  # Ask with custom ensemble (model + system_prompt pairs)
  # Example:
  #   client.ask_ensemble("Explain X", [
  #     { model: "llama3.2:1b", system_prompt: "Be concise" },
  #     { model: "mistral", system_prompt: "Be detailed" },
  #   ])
  sig do
    params(
      question: String,
      ensemble: T::Array[T::Hash[Symbol, String]],
    ).returns(Result)
  end
  def ask_ensemble(question, ensemble)
    ask_with_details(question, ensemble: ensemble)
  end

  private

  sig { params(question: String, system_prompt: T.nilable(String)).returns(T::Array[T::Hash[Symbol, String]]) }
  def build_messages(question, system_prompt)
    messages = T.let([], T::Array[T::Hash[Symbol, String]])
    messages << { role: "system", content: system_prompt } if system_prompt
    messages << { role: "user", content: question }
    messages
  end

  sig do
    params(
      messages: T::Array[T::Hash[Symbol, String]],
      ensemble: T.nilable(T::Array[T::Hash[Symbol, String]]),
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def build_request_body(messages, ensemble)
    body = T.let({
      model: "trio-1.0",
      messages: messages,
      max_tokens: 2048,
    }, T::Hash[Symbol, T.untyped])

    body[:trio_ensemble] = ensemble if ensemble.present?

    body
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
      T.nilable(String),
    ) || "Sorry, I couldn't generate a response."

    # Parse voting details from X-Trio-Details header
    voting_details = parse_voting_details(response.headers["X-Trio-Details"])

    Result.new(content: content.strip, voting_details: voting_details)
  end

  sig { params(header_value: T.nilable(String)).returns(T.nilable(VotingDetails)) }
  def parse_voting_details(header_value)
    return nil if header_value.blank?

    parsed = T.cast(JSON.parse(header_value), T::Hash[String, T.untyped])
    VotingDetails.new(
      winner_index: T.cast(parsed["winner_index"], Integer),
      candidates: T.cast(parsed["candidates"], T::Array[T::Hash[String, T.untyped]]),
    )
  rescue JSON::ParserError
    nil
  end

  sig { returns(Faraday::Connection) }
  def connection
    @connection ||= T.let(
      Faraday.new(url: @base_url) do |f|
        f.options.timeout = @timeout
        f.options.open_timeout = 10
      end,
      T.nilable(Faraday::Connection),
    )
  end
end
