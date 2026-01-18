# typed: strict
# frozen_string_literal: true

# Provides Harmonic-specific assistant behavior for LLM interactions.
# Includes the system prompt and response post-processing.
module HarmonicAssistant
  extend T::Sig

  SYSTEM_PROMPT_TEMPLATE = <<~PROMPT
    You are a helpful assistant for Harmonic, a social agency platform.

    %{context}

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

  sig { returns(String) }
  def self.system_prompt
    context = load_context
    format(SYSTEM_PROMPT_TEMPLATE, context: context)
  end

  sig { params(content: String).returns(String) }
  def self.strip_thinking(content)
    # Remove <thinking>...</thinking> blocks (including multiline)
    content.gsub(%r{<thinking>.*?</thinking>}m, "").strip
  end

  sig { returns(String) }
  def self.load_context
    context_path = Rails.root.join("mcp-server/CONTEXT.md")
    File.exist?(context_path) ? File.read(context_path) : ""
  end
end
