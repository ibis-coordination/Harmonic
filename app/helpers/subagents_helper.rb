# typed: false

module SubagentsHelper
  # Strip trailing JSON action block from LLM response for display.
  # The JSON action is shown in the subsequent step, so it's redundant here.
  #
  # Handles both fenced code blocks (```json...```) and raw JSON at the end.
  def strip_trailing_json_action(response)
    return "" if response.blank?

    response
      .to_s
      .sub(/```json\s*\{(?:(?!```).)*\}\s*```\s*\z/m, "")
      .sub(/\{"type":\s*"[^"]+",.*\}\s*\z/m, "")
      .strip
  end
end
