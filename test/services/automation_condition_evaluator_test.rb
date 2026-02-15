# typed: false

require "test_helper"

class AutomationConditionEvaluatorTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )
  end

  # === Basic Operator Tests ===

  test "equal operator matches exact string" do
    context = { "status" => "active" }
    condition = { "field" => "status", "operator" => "==", "value" => "active" }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "equal operator rejects different string" do
    context = { "status" => "active" }
    condition = { "field" => "status", "operator" => "==", "value" => "inactive" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "not_equal operator matches different string" do
    context = { "status" => "active" }
    condition = { "field" => "status", "operator" => "!=", "value" => "inactive" }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "not_equal operator rejects same string" do
    context = { "status" => "active" }
    condition = { "field" => "status", "operator" => "!=", "value" => "active" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "greater_than operator with numeric values" do
    context = { "count" => 10 }
    condition = { "field" => "count", "operator" => ">", "value" => 5 }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "greater_than operator returns false when equal" do
    context = { "count" => 10 }
    condition = { "field" => "count", "operator" => ">", "value" => 10 }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "greater_than_or_equal operator matches equal values" do
    context = { "count" => 10 }
    condition = { "field" => "count", "operator" => ">=", "value" => 10 }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "greater_than_or_equal operator matches greater values" do
    context = { "count" => 15 }
    condition = { "field" => "count", "operator" => ">=", "value" => 10 }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "less_than operator with numeric values" do
    context = { "count" => 3 }
    condition = { "field" => "count", "operator" => "<", "value" => 5 }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "less_than operator returns false when equal" do
    context = { "count" => 5 }
    condition = { "field" => "count", "operator" => "<", "value" => 5 }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "less_than_or_equal operator matches equal values" do
    context = { "count" => 5 }
    condition = { "field" => "count", "operator" => "<=", "value" => 5 }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "less_than_or_equal operator matches lesser values" do
    context = { "count" => 3 }
    condition = { "field" => "count", "operator" => "<=", "value" => 5 }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  # === String Operators ===

  test "contains operator finds substring" do
    context = { "message" => "Hello World" }
    condition = { "field" => "message", "operator" => "contains", "value" => "World" }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "contains operator is case-sensitive" do
    context = { "message" => "Hello World" }
    condition = { "field" => "message", "operator" => "contains", "value" => "world" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "not_contains operator rejects substring presence" do
    context = { "message" => "Hello World" }
    condition = { "field" => "message", "operator" => "not_contains", "value" => "World" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "not_contains operator accepts missing substring" do
    context = { "message" => "Hello World" }
    condition = { "field" => "message", "operator" => "not_contains", "value" => "Goodbye" }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  # === Regex Operators ===

  test "matches operator with simple regex" do
    context = { "email" => "user@example.com" }
    condition = { "field" => "email", "operator" => "matches", "value" => ".*@example\\.com$" }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "matches operator rejects non-matching pattern" do
    context = { "email" => "user@other.com" }
    condition = { "field" => "email", "operator" => "matches", "value" => ".*@example\\.com$" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "not_matches operator accepts non-matching pattern" do
    context = { "email" => "user@other.com" }
    condition = { "field" => "email", "operator" => "not_matches", "value" => ".*@example\\.com$" }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "not_matches operator rejects matching pattern" do
    context = { "email" => "user@example.com" }
    condition = { "field" => "email", "operator" => "not_matches", "value" => ".*@example\\.com$" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "matches operator handles invalid regex gracefully" do
    context = { "text" => "some text" }
    condition = { "field" => "text", "operator" => "matches", "value" => "[invalid(regex" }

    # Invalid regex should return false, not raise
    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "not_matches operator handles invalid regex gracefully" do
    context = { "text" => "some text" }
    condition = { "field" => "text", "operator" => "not_matches", "value" => "[invalid(regex" }

    # Invalid regex should return false
    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  # === Nested Field Path Resolution ===

  test "resolves simple field path" do
    context = { "name" => "Alice" }
    result = AutomationConditionEvaluator.resolve_field_path("name", context)

    assert_equal "Alice", result
  end

  test "resolves nested field path" do
    context = { "user" => { "profile" => { "name" => "Bob" } } }
    result = AutomationConditionEvaluator.resolve_field_path("user.profile.name", context)

    assert_equal "Bob", result
  end

  test "resolves deeply nested field path" do
    context = { "a" => { "b" => { "c" => { "d" => { "value" => 42 } } } } }
    result = AutomationConditionEvaluator.resolve_field_path("a.b.c.d.value", context)

    assert_equal 42, result
  end

  test "returns nil for missing top-level field" do
    context = { "name" => "Alice" }
    result = AutomationConditionEvaluator.resolve_field_path("missing", context)

    assert_nil result
  end

  test "returns nil for missing nested field" do
    context = { "user" => { "name" => "Alice" } }
    result = AutomationConditionEvaluator.resolve_field_path("user.email", context)

    assert_nil result
  end

  test "returns nil when intermediate path is missing" do
    context = { "user" => { "name" => "Alice" } }
    result = AutomationConditionEvaluator.resolve_field_path("user.profile.email", context)

    assert_nil result
  end

  test "returns nil when path traverses non-hash value" do
    context = { "user" => "not a hash" }
    result = AutomationConditionEvaluator.resolve_field_path("user.name", context)

    assert_nil result
  end

  # === evaluate_all Tests ===

  test "evaluate_all returns true for empty conditions" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    assert AutomationConditionEvaluator.evaluate_all([], event)
  end

  test "evaluate_all returns true for nil conditions" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    assert AutomationConditionEvaluator.evaluate_all(nil, event)
  end

  test "evaluate_all returns true when all conditions pass" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    conditions = [
      { "field" => "event.type", "operator" => "==", "value" => "note.created" },
      { "field" => "subject.type", "operator" => "==", "value" => "note" },
    ]

    assert AutomationConditionEvaluator.evaluate_all(conditions, event)
  end

  test "evaluate_all returns false when any condition fails" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    conditions = [
      { "field" => "event.type", "operator" => "==", "value" => "note.created" },
      { "field" => "event.type", "operator" => "==", "value" => "decision.created" }, # This will fail
    ]

    assert_not AutomationConditionEvaluator.evaluate_all(conditions, event)
  end

  test "evaluate_all with event actor context" do
    note = create_note
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "note.created",
      actor: @user,
      subject: note
    )

    conditions = [
      { "field" => "event.actor.id", "operator" => "==", "value" => @user.id },
    ]

    assert AutomationConditionEvaluator.evaluate_all(conditions, event)
  end

  # === Edge Cases ===

  test "evaluate_condition returns false for missing field" do
    context = {}
    condition = { "field" => "missing", "operator" => "==", "value" => "test" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "evaluate_condition returns false for nil field" do
    context = { "field" => nil }
    condition = { "field" => "field", "operator" => "==", "value" => "test" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "evaluate_condition returns false for missing operator" do
    context = { "status" => "active" }
    condition = { "field" => "status", "value" => "active" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "evaluate_condition returns false for invalid operator" do
    context = { "status" => "active" }
    condition = { "field" => "status", "operator" => "invalid_op", "value" => "active" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "equal operator with numeric string comparison" do
    context = { "count" => 42 }
    condition = { "field" => "count", "operator" => "==", "value" => "42" }

    # Uses string comparison, so 42 == "42" should work
    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "equal operator with boolean values" do
    context = { "enabled" => true }
    condition = { "field" => "enabled", "operator" => "==", "value" => "true" }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "numeric comparison with string values" do
    context = { "count" => "10" }
    condition = { "field" => "count", "operator" => ">", "value" => "5" }

    # String "10" converted to float 10.0 should be > 5.0
    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "numeric comparison with float values" do
    context = { "price" => 19.99 }
    condition = { "field" => "price", "operator" => ">=", "value" => 10.00 }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "contains with nil actual value converts to empty string" do
    context = { "message" => nil }
    condition = { "field" => "message", "operator" => "contains", "value" => "test" }

    # nil.to_s == "", which doesn't contain "test"
    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "contains with numeric values converts to strings" do
    context = { "code" => 12345 }
    condition = { "field" => "code", "operator" => "contains", "value" => "234" }

    assert AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  # === ReDoS Protection Tests ===

  test "rejects overly long regex patterns" do
    context = { "text" => "test" }
    long_pattern = "a" * 600
    condition = { "field" => "text", "operator" => "matches", "value" => long_pattern }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "detects dangerous nested quantifier pattern" do
    assert AutomationConditionEvaluator.dangerous_regex_pattern?("(a+)+")
    assert AutomationConditionEvaluator.dangerous_regex_pattern?("(a*)*")
    assert AutomationConditionEvaluator.dangerous_regex_pattern?("(a+)*")
    assert AutomationConditionEvaluator.dangerous_regex_pattern?("(.*)+")
  end

  test "detects dangerous alternation with quantifier" do
    assert AutomationConditionEvaluator.dangerous_regex_pattern?("(a|b)+")
    assert AutomationConditionEvaluator.dangerous_regex_pattern?("(foo|bar)*")
  end

  test "detects excessive repetition bounds" do
    assert AutomationConditionEvaluator.dangerous_regex_pattern?("a{1,10000}")
    assert AutomationConditionEvaluator.dangerous_regex_pattern?("x{0,99999}")
  end

  test "allows safe regex patterns" do
    assert_not AutomationConditionEvaluator.dangerous_regex_pattern?("^hello$")
    assert_not AutomationConditionEvaluator.dangerous_regex_pattern?("\\d+")
    assert_not AutomationConditionEvaluator.dangerous_regex_pattern?("[a-z]+")
    assert_not AutomationConditionEvaluator.dangerous_regex_pattern?("foo.*bar")
    assert_not AutomationConditionEvaluator.dangerous_regex_pattern?("a{1,10}")
  end

  test "rejects dangerous regex patterns in condition" do
    context = { "text" => "aaaaaaaaaaaa" }
    condition = { "field" => "text", "operator" => "matches", "value" => "(a+)+" }

    assert_not AutomationConditionEvaluator.evaluate_condition(condition, context)
  end

  test "safe regex match works with valid patterns" do
    assert AutomationConditionEvaluator.safe_regex_match?("^hello", "hello world")
    assert AutomationConditionEvaluator.safe_regex_match?("\\d{3}", "abc123def")
    assert_not AutomationConditionEvaluator.safe_regex_match?("^foo$", "bar")
  end
end
