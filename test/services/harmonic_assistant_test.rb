require "test_helper"

class HarmonicAssistantTest < ActiveSupport::TestCase
  test "system_prompt includes Harmonic assistant intro" do
    prompt = HarmonicAssistant.system_prompt

    assert_includes prompt, "helpful assistant for Harmonic"
    assert_includes prompt, "social agency platform"
  end

  test "system_prompt includes thinking tag instructions" do
    prompt = HarmonicAssistant.system_prompt

    assert_includes prompt, "<thinking>"
    assert_includes prompt, "</thinking>"
  end

  test "strip_thinking removes thinking tags from response" do
    content = <<~CONTENT
      <thinking>
      The user is asking about notes.
      Let me explain how to create one.
      </thinking>
      To create a note, click the 'New Note' button.
    CONTENT

    result = HarmonicAssistant.strip_thinking(content)

    assert_equal "To create a note, click the 'New Note' button.", result
    assert_not_includes result, "<thinking>"
    assert_not_includes result, "</thinking>"
  end

  test "strip_thinking handles response with no thinking tags" do
    content = "This is a simple response without thinking tags."

    result = HarmonicAssistant.strip_thinking(content)

    assert_equal "This is a simple response without thinking tags.", result
  end

  test "strip_thinking handles multiple thinking blocks" do
    content = <<~CONTENT
      <thinking>First thought</thinking>
      First answer.
      <thinking>Second thought</thinking>
      Second answer.
    CONTENT

    result = HarmonicAssistant.strip_thinking(content)

    assert_equal "First answer.\n\nSecond answer.", result
    assert_not_includes result, "<thinking>"
  end

  test "strip_thinking preserves content outside thinking tags" do
    content = "<thinking>Internal reasoning</thinking>The actual answer with <code>tags</code>."

    result = HarmonicAssistant.strip_thinking(content)

    assert_equal "The actual answer with <code>tags</code>.", result
  end
end
