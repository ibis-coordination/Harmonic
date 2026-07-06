# typed: false
require "test_helper"

class AiAgentsHelperTest < ActionView::TestCase
  include AiAgentsHelper

  test "strip_trailing_json_action removes fenced JSON block at end" do
    response = <<~RESPONSE
      I will go to the collective to create a note.

      Let me check the available actions first.

      ```json
      {"type": "navigate", "path": "/collectives/test"}
      ```
    RESPONSE

    result = strip_trailing_json_action(response)

    assert_includes result, "I will go to the collective"
    assert_includes result, "Let me check the available actions first."
    assert_not_includes result, "```json"
    assert_not_includes result, '"type"'
    assert_not_includes result, '"/collectives/test"'
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

  # === safe_internal_path? ===
  #
  # Guards the `display_path` -> `<a href>` render in show_mcp_tool_call and
  # show_run against a scheme-bearing value ever reaching the column. These
  # cases are the exploit shapes a regression would have to slip through.

  test "safe_internal_path? accepts a same-origin relative path" do
    assert safe_internal_path?("/collectives/team/n/abc123")
    assert safe_internal_path?("/workspace/foo/d/xyz?comment_id=q1")
    assert safe_internal_path?("/")
  end

  test "safe_internal_path? rejects a javascript: URI" do
    assert_not safe_internal_path?("javascript:alert(document.cookie)")
    assert_not safe_internal_path?("JavaScript:alert(1)")
  end

  test "safe_internal_path? rejects data: and other schemes" do
    assert_not safe_internal_path?("data:text/html,<script>alert(1)</script>")
    assert_not safe_internal_path?("http://evil.example/x")
    assert_not safe_internal_path?("https://evil.example/x")
  end

  test "safe_internal_path? rejects a protocol-relative host" do
    assert_not safe_internal_path?("//evil.example/x")
  end

  test "safe_internal_path? rejects blank and nil" do
    assert_not safe_internal_path?(nil)
    assert_not safe_internal_path?("")
    assert_not safe_internal_path?("   ")
  end

  test "available_llm_models returns models from litellm config" do
    models = available_llm_models

    assert_kind_of Array, models
    assert_not_empty models
    assert_includes models, "default"
  end

  test "available_llm_models returns all configured models" do
    models = available_llm_models

    # These models are defined in config/litellm_config.yaml. Gateway-servable
    # models use the Stripe gateway's provider/model names 1-to-1.
    assert_includes models, "default"
    assert_includes models, "anthropic/claude-haiku-4.5"
    assert_includes models, "llama3"
  end
end
