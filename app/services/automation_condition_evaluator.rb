# typed: true

class AutomationConditionEvaluator
  extend T::Sig

  OPERATORS = {
    "==" => :equal,
    "!=" => :not_equal,
    ">" => :greater_than,
    ">=" => :greater_than_or_equal,
    "<" => :less_than,
    "<=" => :less_than_or_equal,
    "contains" => :contains,
    "not_contains" => :not_contains,
    "matches" => :matches,
    "not_matches" => :not_matches,
  }.freeze

  # Evaluate all conditions against an event - all must pass
  sig { params(conditions: T.untyped, event: Event).returns(T::Boolean) }
  def self.evaluate_all(conditions, event)
    return true if conditions.blank?
    return true unless conditions.is_a?(Array)

    context = AutomationTemplateRenderer.context_from_event(event)

    conditions.all? do |condition|
      evaluate_condition(condition, context)
    end
  end

  # Evaluate a single condition against a context
  sig { params(condition: T::Hash[String, T.untyped], context: T::Hash[String, T.untyped]).returns(T::Boolean) }
  def self.evaluate_condition(condition, context)
    field = condition["field"]
    operator = condition["operator"]
    expected_value = condition["value"]

    return false unless field.present? && operator.present?

    actual_value = resolve_field_path(field, context)

    apply_operator(operator, actual_value, expected_value)
  end

  NestedValue = T.type_alias { T.nilable(T.any(String, Integer, Float, T::Boolean, T::Hash[String, T.untyped], T::Array[T.untyped])) }

  # Resolve a dotted field path against a context hash
  sig { params(path: String, context: T::Hash[String, T.untyped]).returns(NestedValue) }
  def self.resolve_field_path(path, context)
    parts = path.split(".")
    resolve_path_recursive(context, parts)
  end

  sig { params(current: NestedValue, remaining_parts: T::Array[String]).returns(NestedValue) }
  def self.resolve_path_recursive(current, remaining_parts)
    return current if remaining_parts.empty?
    return nil unless current.is_a?(Hash)

    part = remaining_parts.first
    return nil if part.nil?

    next_value = current[part]
    resolve_path_recursive(next_value, remaining_parts.drop(1))
  end

  # Apply an operator to compare values
  sig { params(operator: String, actual: T.untyped, expected: T.untyped).returns(T::Boolean) }
  def self.apply_operator(operator, actual, expected)
    case OPERATORS[operator]
    when :equal
      compare_equal(actual, expected)
    when :not_equal
      !compare_equal(actual, expected)
    when :greater_than
      compare_numeric(actual, expected) { |a, e| a > e }
    when :greater_than_or_equal
      compare_numeric(actual, expected) { |a, e| a >= e }
    when :less_than
      compare_numeric(actual, expected) { |a, e| a < e }
    when :less_than_or_equal
      compare_numeric(actual, expected) { |a, e| a <= e }
    when :contains
      actual.to_s.include?(expected.to_s)
    when :not_contains
      actual.to_s.exclude?(expected.to_s)
    when :matches
      Regexp.new(expected.to_s).match?(actual.to_s)
    when :not_matches
      !Regexp.new(expected.to_s).match?(actual.to_s)
    else
      false
    end
  rescue RegexpError
    # Invalid regex pattern
    false
  end

  sig { params(actual: T.untyped, expected: T.untyped).returns(T::Boolean) }
  def self.compare_equal(actual, expected)
    # Use string comparison to avoid float precision issues
    actual.to_s == expected.to_s
  end

  sig { params(actual: T.untyped, expected: T.untyped, block: T.proc.params(a: Numeric, e: Numeric).returns(T::Boolean)).returns(T::Boolean) }
  def self.compare_numeric(actual, expected, &block)
    a = actual.to_f
    e = expected.to_f
    block.call(a, e)
  rescue StandardError
    false
  end
end
