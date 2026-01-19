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
    const :aggregation_method, String
    const :candidates, T::Array[T::Hash[String, T.untyped]]
  end

  # Result with both response and voting metadata
  class Result < T::Struct
    const :content, String
    const :voting_details, T.nilable(VotingDetails)
  end

  # Valid aggregation methods
  AGGREGATION_METHODS = T.let(
    ["acceptance_voting", "random", "judge", "synthesize", "concat"].freeze,
    T::Array[String]
  )

  # Default system prompts for ensemble variety
  # Each prompt encourages a different response style
  DEFAULT_SYSTEM_PROMPTS = T.let(
    [
      "You are a concise assistant. Give direct, to-the-point answers. Avoid unnecessary elaboration.",
      "You are a thorough assistant. Provide detailed, comprehensive responses with examples when helpful.",
      "You are a balanced assistant. Give clear, well-structured answers that cover key points without being verbose.",
    ].freeze,
    T::Array[String]
  )

  sig { void }
  def initialize
    @base_url = T.let(ENV.fetch("TRIO_BASE_URL", "http://trio:8000"), String)
    @timeout = T.let(ENV.fetch("TRIO_TIMEOUT", "120").to_i, Integer)
    @default_models = T.let(
      ENV.fetch("TRIO_MODELS", "default,default,default").split(",").map(&:strip),
      T::Array[String]
    )
    @default_system_prompts = T.let(
      parse_system_prompts(ENV.fetch("TRIO_SYSTEM_PROMPTS", nil)),
      T::Array[String]
    )
    @default_aggregation = T.let(
      ENV.fetch("TRIO_AGGREGATION_METHOD", "acceptance_voting"),
      String
    )
    @default_judge_model = T.let(ENV.fetch("TRIO_JUDGE_MODEL", nil), T.nilable(String))
    @default_synthesize_model = T.let(ENV.fetch("TRIO_SYNTHESIZE_MODEL", nil), T.nilable(String))
  end

  # Simple ask - returns just the response content
  sig { params(question: String, system_prompt: T.nilable(String)).returns(String) }
  def ask(question, system_prompt: nil)
    ask_with_details(question, system_prompt: system_prompt).content
  end

  # Ask with full voting details
  # Options:
  #   ensemble: Array of model configs (each with :model key, optional :system_prompt)
  #   aggregation_method: One of acceptance_voting, random, judge, synthesize, concat
  #   judge_model: Model to use for judge aggregation (required if aggregation_method is judge)
  #   synthesize_model: Model to use for synthesize aggregation (required if aggregation_method is synthesize)
  sig do
    params(
      question: String,
      system_prompt: T.nilable(String),
      ensemble: T.nilable(T::Array[T::Hash[Symbol, String]]),
      aggregation_method: T.nilable(String),
      judge_model: T.nilable(String),
      synthesize_model: T.nilable(String)
    ).returns(Result)
  end
  def ask_with_details(question, system_prompt: nil, ensemble: nil, aggregation_method: nil, judge_model: nil, synthesize_model: nil)
    messages = build_messages(question, system_prompt)
    aggregation_opts = {
      aggregation_method: aggregation_method,
      judge_model: judge_model,
      synthesize_model: synthesize_model,
    }
    body = build_request_body(messages, ensemble, aggregation_opts)

    response = make_request(body)
    parse_response(response)
  rescue Faraday::Error, JSON::ParserError => e
    Rails.logger.error("TrioClient error: #{e.message}")
    Result.new(
      content: "Sorry, there was an error connecting to the Trio service. Please try again later.",
      voting_details: nil
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
      ensemble: T::Array[T::Hash[Symbol, String]]
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
      aggregation_opts: T::Hash[Symbol, T.nilable(String)]
    ).returns(T::Hash[Symbol, T.untyped])
  end
  def build_request_body(messages, ensemble, aggregation_opts = {})
    # Build the model config - either custom ensemble or default from env
    # Ensemble members must be objects with a "model" key and optional "system_prompt"
    ensemble_members = ensemble.presence || build_default_ensemble

    # Use provided aggregation method or fall back to default
    aggregation_method = aggregation_opts[:aggregation_method] || @default_aggregation

    model_config = T.let({
                           ensemble: ensemble_members,
                           aggregation_method: aggregation_method,
                         }, T::Hash[Symbol, T.untyped])

    # Add judge_model if using judge aggregation
    if aggregation_method == "judge"
      judge_model = aggregation_opts[:judge_model] || @default_judge_model
      model_config[:judge_model] = judge_model if judge_model.present?
    end

    # Add synthesize_model if using synthesize aggregation
    if aggregation_method == "synthesize"
      synthesize_model = aggregation_opts[:synthesize_model] || @default_synthesize_model
      model_config[:synthesize_model] = synthesize_model if synthesize_model.present?
    end

    {
      model: model_config,
      messages: messages,
      max_tokens: 2048,
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
      aggregation_method: T.cast(parsed["aggregation_method"], String),
      candidates: T.cast(parsed["candidates"], T::Array[T::Hash[String, T.untyped]])
    )
  rescue JSON::ParserError
    nil
  end

  sig { returns(T::Array[T::Hash[Symbol, String]]) }
  def build_default_ensemble
    @default_models.each_with_index.map do |model, index|
      member = T.let({ model: model }, T::Hash[Symbol, String])
      # Add system prompt if available for this index
      system_prompt = @default_system_prompts[index]
      member[:system_prompt] = system_prompt if system_prompt.present?
      member
    end
  end

  sig { params(env_value: T.nilable(String)).returns(T::Array[String]) }
  def parse_system_prompts(env_value)
    return DEFAULT_SYSTEM_PROMPTS if env_value.blank?

    # Parse pipe-delimited system prompts from env var
    # Example: "Be concise|Be detailed|Be balanced"
    prompts = env_value.split("|").map(&:strip).reject(&:blank?)
    prompts.presence || DEFAULT_SYSTEM_PROMPTS
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
