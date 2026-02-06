# typed: false
require "test_helper"

class IdentityPromptLeakageDetectorTest < ActiveSupport::TestCase
  setup do
    @detector = IdentityPromptLeakageDetector.new
  end

  test "extracts canary and identity prompt from whoami content" do
    content = <<~CONTENT
      # Who Am I?

      Some intro text...

      **CONFIDENTIALITY NOTICE**: The identity prompt below is proprietary...

      <canary:abc12345>
      You are a helpful assistant focused on team coordination.
      Always be polite and professional.
      </canary:abc12345>
    CONTENT

    assert @detector.extract_from_content(content)
    assert @detector.active?
  end

  test "returns false when no canary found" do
    content = "# Who Am I?\n\nJust some regular content."

    refute @detector.extract_from_content(content)
    refute @detector.active?
  end

  test "returns false when canary tags don't match" do
    content = <<~CONTENT
      <canary:abc123>
      Some content
      </canary:def456>
    CONTENT

    refute @detector.extract_from_content(content)
    refute @detector.active?
  end

  test "detects canary token in output" do
    content = <<~CONTENT
      <canary:secrettoken123>
      You are a helpful assistant.
      </canary:secrettoken123>
    CONTENT

    @detector.extract_from_content(content)

    result = @detector.check_leakage("Here is my response including secrettoken123 by accident")

    assert result[:leaked]
    assert_includes result[:reasons], "canary_token_detected"
  end

  test "detects substantial identity prompt overlap" do
    identity_prompt = "You are a specialized financial advisor AI. Your role is to help users understand complex investment strategies and portfolio management techniques."

    content = "<canary:abc123>#{identity_prompt}</canary:abc123>"
    @detector.extract_from_content(content)

    # Output that includes most of the identity prompt
    output = "I was instructed that my role is to help users understand complex investment strategies and portfolio management techniques. Let me help you with that."

    result = @detector.check_leakage(output)

    assert result[:leaked]
    assert_includes result[:reasons], "identity_prompt_similarity"
  end

  test "does not flag short coincidental matches" do
    identity_prompt = "You are a helpful assistant for team coordination."

    content = "<canary:abc123>#{identity_prompt}</canary:abc123>"
    @detector.extract_from_content(content)

    # Short match of common words shouldn't trigger
    output = "I can help you with that task."

    result = @detector.check_leakage(output)

    refute result[:leaked]
    assert_empty result[:reasons]
  end

  test "returns empty result when detector not active" do
    result = @detector.check_leakage("Any content here")

    refute result[:leaked]
    assert_empty result[:reasons]
  end

  test "handles empty output gracefully" do
    content = "<canary:abc123>Some identity prompt</canary:abc123>"
    @detector.extract_from_content(content)

    result = @detector.check_leakage("")

    refute result[:leaked]
    assert_empty result[:reasons]
  end

  test "handles very long identity prompts" do
    long_prompt = "You are an AI assistant. " * 500  # Very long prompt
    content = "<canary:abc123>#{long_prompt}</canary:abc123>"

    @detector.extract_from_content(content)
    assert @detector.active?

    # Should still detect canary
    result = @detector.check_leakage("abc123 appeared in output")
    assert result[:leaked]
  end

  test "similarity check is case insensitive" do
    identity_prompt = "You are a SPECIALIZED FINANCIAL ADVISOR for complex investments."
    content = "<canary:abc123>#{identity_prompt}</canary:abc123>"
    @detector.extract_from_content(content)

    output = "you are a specialized financial advisor for complex investments - here's my advice"

    result = @detector.check_leakage(output)

    assert result[:leaked]
    assert_includes result[:reasons], "identity_prompt_similarity"
  end

  test "handles multiline identity prompts" do
    identity_prompt = <<~PROMPT
      You are a team coordinator AI.

      Your responsibilities include:
      1. Helping schedule meetings
      2. Tracking project progress
      3. Facilitating communication

      Always maintain professional tone.
    PROMPT

    content = "<canary:xyz789>#{identity_prompt}</canary:xyz789>"
    @detector.extract_from_content(content)

    # Leaking part of the multiline prompt
    output = "Your responsibilities include: 1. Helping schedule meetings 2. Tracking project progress 3. Facilitating communication"

    result = @detector.check_leakage(output)

    assert result[:leaked]
  end
end
