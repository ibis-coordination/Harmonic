# typed: true

class AutomationConditionEvaluator
  extend T::Sig

  # Maximum allowed length for regex patterns to prevent complexity attacks
  MAX_REGEX_LENGTH = 500

  # Timeout for regex matching (in seconds)
  REGEX_TIMEOUT = 1

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
      safe_regex_match(expected.to_s, actual.to_s) == true
    when :not_matches
      result = safe_regex_match(expected.to_s, actual.to_s)
      # If regex is invalid (nil), return false rather than claiming "doesn't match"
      return false if result.nil?

      !result
    else
      false
    end
  rescue RegexpError
    # Invalid regex pattern
    false
  end

  # Safely execute a regex match with length limits and timeout protection.
  # Returns true (matches), false (doesn't match), or nil (error/invalid).
  # Uses Ruby 3.2+ native Regexp.timeout for reliable ReDoS protection.
  sig { params(pattern: String, text: String).returns(T.nilable(T::Boolean)) }
  def self.safe_regex_match(pattern, text)
    # Reject overly long patterns that could be complex
    return nil if pattern.length > MAX_REGEX_LENGTH

    # Reject patterns with known problematic constructs
    return nil if dangerous_regex_pattern?(pattern)

    # Use Ruby 3.2+ native Regexp timeout (more reliable than Timeout.timeout)
    Regexp.new(pattern, timeout: REGEX_TIMEOUT).match?(text)
  rescue Regexp::TimeoutError
    Rails.logger.warn("AutomationConditionEvaluator: Regex timeout for pattern: #{pattern.truncate(50)}")
    nil
  rescue RegexpError
    nil
  end

  # Backward-compatible wrapper that returns boolean only
  sig { params(pattern: String, text: String).returns(T::Boolean) }
  def self.safe_regex_match?(pattern, text)
    safe_regex_match(pattern, text) == true
  end

  # Check for regex patterns known to cause catastrophic backtracking
  sig { params(pattern: String).returns(T::Boolean) }
  def self.dangerous_regex_pattern?(pattern)
    # Detect nested quantifiers like (a+)+, (a*)*,  (a+)*
    # These are common sources of ReDoS vulnerabilities
    nested_quantifier = /\([^)]*[+*]\)[+*]/

    # Detect overlapping alternations with quantifiers like (a|a)+
    # More conservative: flag any alternation followed by a quantifier
    alternation_quantifier = /\([^)]*\|[^)]*\)[+*]{1,}/

    # Detect excessive repetition bounds like {1,10000}
    large_repetition = /\{\d*,\s*(\d{4,})\}/

    pattern.match?(nested_quantifier) ||
      pattern.match?(alternation_quantifier) ||
      pattern.match?(large_repetition)
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
