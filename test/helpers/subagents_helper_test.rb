# typed: false
require "test_helper"

class SubagentsHelperTest < ActionView::TestCase
  include SubagentsHelper

  test "strip_trailing_json_action removes fenced JSON block at end" do
    response = <<~RESPONSE
      I will go to the studio to create a note.

      Let me check the available actions first.

      ```json
      {"type": "navigate", "path": "/studios/test"}
      ```
    RESPONSE

    result = strip_trailing_json_action(response)

    assert_includes result, "I will go to the studio"
    assert_includes result, "Let me check the available actions first."
    assert_not_includes result, "```json"
    assert_not_includes result, '"type"'
    assert_not_includes result, '"/studios/test"'
  end

  test "strip_trailing_json_action removes fenced JSON with nested objects" do
    response = <<~RESPONSE
      I'll create a note with the title "Hello World".

      ```json
      {"type": "execute", "action": "create_note", "params": {"title": "Hello World", "body": "Test content"}}
      ```
    RESPONSE

    result = strip_trailing_json_action(response)

    assert_includes result, "I'll create a note"
    assert_not_includes result, "```json"
    assert_not_includes result, '"params"'
  end

  test "strip_trailing_json_action removes raw JSON at end" do
    response = <<~RESPONSE
      The task is complete. I've created the note successfully.

      {"type": "done", "message": "Created note successfully"}
    RESPONSE

    result = strip_trailing_json_action(response)

    assert_includes result, "The task is complete"
    assert_not_includes result, '"type"'
    assert_not_includes result, '"done"'
  end

  test "strip_trailing_json_action preserves content without JSON" do
    response = "This is just regular text without any JSON."

    result = strip_trailing_json_action(response)

    assert_equal "This is just regular text without any JSON.", result
  end

  test "strip_trailing_json_action handles nil input" do
    result = strip_trailing_json_action(nil)
    assert_equal "", result
  end

  test "strip_trailing_json_action handles blank input" do
    result = strip_trailing_json_action("")
    assert_equal "", result
  end

  test "strip_trailing_json_action preserves JSON in middle of response" do
    response = <<~RESPONSE
      Here's an example of JSON:
      ```json
      {"example": "value"}
      ```
      And here's my actual action:
      ```json
      {"type": "navigate", "path": "/"}
      ```
    RESPONSE

    result = strip_trailing_json_action(response)

    # Should keep the first JSON block but remove the trailing action
    assert_includes result, '{"example": "value"}'
    assert_not_includes result, '"type": "navigate"'
  end

  test "available_llm_models returns models from litellm config" do
    models = available_llm_models

    assert_kind_of Array, models
    assert_not_empty models
    assert_includes models, "default"
  end

  test "available_llm_models returns all configured models" do
    models = available_llm_models

    # These models are defined in config/litellm_config.yaml
    assert_includes models, "default"
    assert_includes models, "claude-haiku-4"
    assert_includes models, "llama3"
  end
end
