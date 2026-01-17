# typed: strict
# frozen_string_literal: true

class LlmClient
  extend T::Sig

  sig { void }
  def initialize
    @base_url = T.let(ENV.fetch("LITELLM_BASE_URL", "http://litellm:4000"), String)
    @model = T.let(ENV.fetch("CHAT_MODEL", "default"), String)
  end

  sig { params(question: String).returns(String) }
  def ask(question)
    response = T.unsafe(Faraday).post("#{@base_url}/v1/chat/completions") do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = {
        model: @model,
        messages: [
          { role: "system", content: system_prompt },
          { role: "user", content: question },
        ],
        max_tokens: 2048,
      }.to_json
    end

    parsed = T.cast(JSON.parse(response.body), T::Hash[String, T.untyped])
    content = T.cast(parsed.dig("choices", 0, "message", "content"), T.nilable(String)) || "Sorry, I couldn't generate a response."
    strip_thinking(content)
  rescue Faraday::Error, JSON::ParserError => e
    Rails.logger.error("LlmClient error: #{e.message}")
    "Sorry, there was an error connecting to the LLM service. Please try again later."
  end

  private

  sig { params(content: String).returns(String) }
  def strip_thinking(content)
    # Remove <thinking>...</thinking> blocks (including multiline)
    content.gsub(%r{<thinking>.*?</thinking>}m, "").strip
  end

  sig { returns(String) }
  def system_prompt
    @system_prompt ||= T.let(begin
      context_path = Rails.root.join("mcp-server/CONTEXT.md")
      context = File.exist?(context_path) ? File.read(context_path) : ""

      <<~PROMPT
        You are a helpful assistant for Harmonic, a social agency platform.

        #{context}

        When answering questions, first think through the problem step by step inside <thinking>...</thinking> tags.
        Then provide your final answer outside the tags.

        Example:
        <thinking>
        The user is asking about X. Let me consider...
        </thinking>
        Here is my answer about X.

        Answer questions about how to use Harmonic. Be concise and helpful.
        If you don't know the answer, say so rather than making something up.
      PROMPT
    end, T.nilable(String))
  end
end
