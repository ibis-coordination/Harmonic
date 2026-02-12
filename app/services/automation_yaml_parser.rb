# typed: true

class AutomationYamlParser
  extend T::Sig

  class ParseError < StandardError; end
  class ValidationError < StandardError; end

  VALID_TRIGGER_TYPES = ["event", "schedule", "webhook"].freeze
  VALID_MENTION_FILTERS = ["self", "any_agent"].freeze
  VALID_CONDITION_OPERATORS = ["==", "!=", ">", ">=", "<", "<=", "contains", "not_contains", "matches", "not_matches"].freeze
  VALID_ACTION_TYPES = ["internal_action", "webhook", "trigger_agent"].freeze

  class Result < T::Struct
    const :success, T::Boolean
    const :attributes, T.nilable(T::Hash[Symbol, T.untyped])
    const :errors, T::Array[String]

    def success?
      success
    end
  end

  sig { params(yaml_string: String, ai_agent_id: T.nilable(String)).returns(Result) }
  def self.parse(yaml_string, ai_agent_id: nil)
    new(yaml_string, ai_agent_id: ai_agent_id).parse
  end

  sig { params(yaml_string: String, ai_agent_id: T.nilable(String)).void }
  def initialize(yaml_string, ai_agent_id: nil)
    @yaml_string = yaml_string
    @ai_agent_id = ai_agent_id
    @errors = T.let([], T::Array[String])
  end

  sig { returns(Result) }
  def parse
    data = parse_yaml
    return error_result if data.nil?

    validate_structure(data)
    return error_result if @errors.any?

    attributes = build_attributes(data)
    validate_attributes(attributes, data)
    return error_result if @errors.any?

    Result.new(success: true, attributes: attributes, errors: [])
  rescue ParseError => e
    @errors << e.message
    error_result
  end

  private

  sig { returns(T.nilable(T::Hash[String, T.untyped])) }
  def parse_yaml
    data = YAML.safe_load(@yaml_string, permitted_classes: [Symbol])
    unless data.is_a?(Hash)
      @errors << "YAML must be a hash/object at the top level"
      return nil
    end
    data.deep_stringify_keys
  rescue Psych::SyntaxError => e
    @errors << "Invalid YAML syntax: #{e.message}"
    nil
  end

  sig { params(data: T::Hash[String, T.untyped]).void }
  def validate_structure(data)
    @errors << "name is required" if data["name"].blank?
    @errors << "trigger is required" unless data["trigger"].is_a?(Hash)

    return unless data["trigger"].is_a?(Hash)

    trigger = data["trigger"]
    @errors << "trigger.type is required" if trigger["type"].blank?

    @errors << "trigger.type must be one of: #{VALID_TRIGGER_TYPES.join(", ")}" unless VALID_TRIGGER_TYPES.include?(trigger["type"])

    validate_trigger_config(trigger)
    validate_conditions(data["conditions"]) if data["conditions"].present?
    validate_actions_or_task(data)
  end

  sig { params(trigger: T::Hash[String, T.untyped]).void }
  def validate_trigger_config(trigger)
    case trigger["type"]
    when "event"
      @errors << "trigger.event_type is required for event triggers" if trigger["event_type"].blank?
      if trigger["mention_filter"].present? && VALID_MENTION_FILTERS.exclude?(trigger["mention_filter"])
        @errors << "trigger.mention_filter must be one of: #{VALID_MENTION_FILTERS.join(", ")}"
      end
    when "schedule"
      @errors << "trigger.cron is required for schedule triggers" if trigger["cron"].blank?
      validate_cron_expression(trigger["cron"]) if trigger["cron"].present?
    when "webhook"
      # No additional required fields for webhook trigger
    end
  end

  sig { params(cron: String).void }
  def validate_cron_expression(cron)
    # Basic validation - 5 fields for standard cron
    fields = cron.to_s.split(/\s+/)
    return if fields.length == 5

    @errors << "trigger.cron must have 5 fields (minute hour day month weekday)"
  end

  sig { params(conditions: T.untyped).void }
  def validate_conditions(conditions)
    return unless conditions.is_a?(Array)

    conditions.each_with_index do |condition, index|
      unless condition.is_a?(Hash)
        @errors << "conditions[#{index}] must be an object"
        next
      end

      @errors << "conditions[#{index}].field is required" if condition["field"].blank?
      @errors << "conditions[#{index}].operator is required" if condition["operator"].blank?

      if condition["operator"].present? && VALID_CONDITION_OPERATORS.exclude?(condition["operator"])
        @errors << "conditions[#{index}].operator must be one of: #{VALID_CONDITION_OPERATORS.join(", ")}"
      end
    end
  end

  sig { params(data: T::Hash[String, T.untyped]).void }
  def validate_actions_or_task(data)
    has_task = data["task"].present?
    has_actions = data["actions"].present?

    if @ai_agent_id.present?
      # Agent rules should have task, not actions
      @errors << "task is required for agent automation rules" unless has_task
      @errors << "actions should not be specified for agent rules (use task instead)" if has_actions
    else
      # General rules should have actions
      @errors << "actions is required for automation rules" unless has_actions || has_task

      validate_actions(data["actions"]) if has_actions
    end
  end

  sig { params(actions: T.untyped).void }
  def validate_actions(actions)
    return unless actions.is_a?(Array)

    actions.each_with_index do |action, index|
      unless action.is_a?(Hash)
        @errors << "actions[#{index}] must be an object"
        next
      end

      @errors << "actions[#{index}].type is required" if action["type"].blank?

      if action["type"].present? && VALID_ACTION_TYPES.exclude?(action["type"])
        @errors << "actions[#{index}].type must be one of: #{VALID_ACTION_TYPES.join(", ")}"
      end

      case action["type"]
      when "internal_action"
        @errors << "actions[#{index}].action is required for internal_action type" if action["action"].blank?
      when "webhook"
        @errors << "actions[#{index}].url is required for webhook type" if action["url"].blank?
      end
    end
  end

  sig { params(data: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  def build_attributes(data)
    trigger = data["trigger"]

    attributes = {
      name: data["name"],
      description: data["description"],
      trigger_type: trigger["type"],
      trigger_config: build_trigger_config(trigger, data),
      conditions: data["conditions"] || [],
      yaml_source: @yaml_string,
    }

    # For agent rules, store task in actions field
    if @ai_agent_id.present? && data["task"].present?
      attributes[:actions] = { "task" => data["task"] }
    elsif data["actions"].present?
      attributes[:actions] = data["actions"]
    end

    attributes
  end

  sig { params(trigger: T::Hash[String, T.untyped], data: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
  def build_trigger_config(trigger, data)
    config = {}

    case trigger["type"]
    when "event"
      config["event_type"] = trigger["event_type"]
      config["mention_filter"] = trigger["mention_filter"] if trigger["mention_filter"].present?
    when "schedule"
      config["cron"] = trigger["cron"]
      config["timezone"] = trigger["timezone"] || "UTC"
    when "webhook"
      # Webhook path is generated by the model
    end

    # Store max_steps from top level
    config["max_steps"] = data["max_steps"].to_i if data["max_steps"].present?

    config
  end

  sig { params(attributes: T::Hash[Symbol, T.untyped], _data: T::Hash[String, T.untyped]).void }
  def validate_attributes(attributes, _data)
    # Additional validation that couldn't be done during parsing
    # Mention filter "self" requires the agent to be set - this is validated elsewhere
    nil if @ai_agent_id.present? && attributes[:trigger_config]["mention_filter"] == "self"
  end

  sig { returns(Result) }
  def error_result
    Result.new(success: false, attributes: nil, errors: @errors)
  end
end
