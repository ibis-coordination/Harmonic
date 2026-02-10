# typed: false

module AiAgentsHelper
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

  # Returns list of available LLM model names from litellm_config.yaml
  def available_llm_models
    config_path = Rails.root.join("config/litellm_config.yaml")
    return ["default"] unless File.exist?(config_path)

    config = YAML.load_file(config_path)
    model_list = config["model_list"] || []
    models = model_list.filter_map { |m| m["model_name"] }
    models.presence || ["default"]
  end
end
