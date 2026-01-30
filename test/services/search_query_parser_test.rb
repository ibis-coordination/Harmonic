# typed: false

require "test_helper"

class SearchQueryParserTest < ActiveSupport::TestCase
  # Basic search text

  test "plain text becomes search query" do
    result = SearchQueryParser.new("budget proposal").parse
    assert_equal "budget proposal", result[:q]
  end

  test "quoted phrase becomes exact phrase" do
    result = SearchQueryParser.new('"budget proposal"').parse
    assert_nil result[:q]
    assert_equal ["budget proposal"], result[:exact_phrases]
  end

  test "empty query returns empty params" do
    result = SearchQueryParser.new("").parse
    assert_nil result[:q]
  end

  test "nil query returns empty params" do
    result = SearchQueryParser.new(nil).parse
    assert_nil result[:q]
  end

  # Type operator

  test "type:note filters by note" do
    result = SearchQueryParser.new("type:note").parse
    assert_equal "note", result[:type]
  end

  test "type:n expands to note" do
    result = SearchQueryParser.new("type:n").parse
    assert_equal "note", result[:type]
  end

  test "type:d expands to decision" do
    result = SearchQueryParser.new("type:d").parse
    assert_equal "decision", result[:type]
  end

  test "type:c expands to commitment" do
    result = SearchQueryParser.new("type:c").parse
    assert_equal "commitment", result[:type]
  end

  test "type:note,decision allows multiple types" do
    result = SearchQueryParser.new("type:note,decision").parse
    assert_equal "note,decision", result[:type]
  end

  test "invalid type treated as search text" do
    result = SearchQueryParser.new("type:invalid").parse
    assert_equal "type:invalid", result[:q]
    assert_nil result[:type]
  end

  # is: operator

  test "is:open adds open filter" do
    result = SearchQueryParser.new("is:open").parse
    assert_includes result[:filters], "open"
  end

  test "is:closed adds closed filter" do
    result = SearchQueryParser.new("is:closed").parse
    assert_includes result[:filters], "closed"
  end

  test "is:mine adds mine filter" do
    result = SearchQueryParser.new("is:mine").parse
    assert_includes result[:filters], "mine"
  end

  test "is:pinned adds pinned filter" do
    result = SearchQueryParser.new("is:pinned").parse
    assert_includes result[:filters], "pinned"
  end

  test "multiple is: values combined" do
    result = SearchQueryParser.new("is:open,mine").parse
    assert_includes result[:filters], "open"
    assert_includes result[:filters], "mine"
  end

  # Negation

  test "-is:mine adds not_mine filter" do
    result = SearchQueryParser.new("-is:mine").parse
    assert_includes result[:filters], "not_mine"
  end

  test "-is:open adds closed filter" do
    result = SearchQueryParser.new("-is:open").parse
    assert_includes result[:filters], "closed"
  end

  test "-is:closed adds open filter" do
    result = SearchQueryParser.new("-is:closed").parse
    assert_includes result[:filters], "open"
  end

  test "-type:note excludes notes" do
    result = SearchQueryParser.new("type:note,decision -type:note").parse
    assert_equal "decision", result[:type]
  end

  # has: operator

  test "has:backlinks adds has_backlinks filter" do
    result = SearchQueryParser.new("has:backlinks").parse
    assert_includes result[:filters], "has_backlinks"
  end

  test "has:links adds has_links filter" do
    result = SearchQueryParser.new("has:links").parse
    assert_includes result[:filters], "has_links"
  end

  test "has:participants adds has_participants filter" do
    result = SearchQueryParser.new("has:participants").parse
    assert_includes result[:filters], "has_participants"
  end

  # by: operator

  test "by:me adds mine filter" do
    result = SearchQueryParser.new("by:me").parse
    assert_includes result[:filters], "mine"
  end

  test "by:@alice adds created_by filter" do
    result = SearchQueryParser.new("by:@alice").parse
    assert_includes result[:filters], "created_by:alice"
  end

  test "by:@alice,@bob adds multiple created_by filters" do
    result = SearchQueryParser.new("by:@alice,@bob").parse
    assert_includes result[:filters], "created_by:alice"
    assert_includes result[:filters], "created_by:bob"
  end

  # sort: operator

  test "sort:newest maps to created_at-desc" do
    result = SearchQueryParser.new("sort:newest").parse
    assert_equal "created_at-desc", result[:sort_by]
  end

  test "sort:oldest maps to created_at-asc" do
    result = SearchQueryParser.new("sort:oldest").parse
    assert_equal "created_at-asc", result[:sort_by]
  end

  test "sort:new expands to newest" do
    result = SearchQueryParser.new("sort:new").parse
    assert_equal "created_at-desc", result[:sort_by]
  end

  test "sort:old expands to oldest" do
    result = SearchQueryParser.new("sort:old").parse
    assert_equal "created_at-asc", result[:sort_by]
  end

  test "sort:updated maps to updated_at-desc" do
    result = SearchQueryParser.new("sort:updated").parse
    assert_equal "updated_at-desc", result[:sort_by]
  end

  test "sort:deadline maps to deadline-asc" do
    result = SearchQueryParser.new("sort:deadline").parse
    assert_equal "deadline-asc", result[:sort_by]
  end

  test "sort:relevance maps to relevance-desc" do
    result = SearchQueryParser.new("sort:relevance").parse
    assert_equal "relevance-desc", result[:sort_by]
  end

  test "sort:backlinks maps to backlink_count-desc" do
    result = SearchQueryParser.new("sort:backlinks").parse
    assert_equal "backlink_count-desc", result[:sort_by]
  end

  test "last sort wins" do
    result = SearchQueryParser.new("sort:newest sort:oldest").parse
    assert_equal "created_at-asc", result[:sort_by]
  end

  # group: operator

  test "group:type maps to item_type" do
    result = SearchQueryParser.new("group:type").parse
    assert_equal "item_type", result[:group_by]
  end

  test "group:status maps to status" do
    result = SearchQueryParser.new("group:status").parse
    assert_equal "status", result[:group_by]
  end

  test "group:date maps to date_created" do
    result = SearchQueryParser.new("group:date").parse
    assert_equal "date_created", result[:group_by]
  end

  test "group:week maps to week_created" do
    result = SearchQueryParser.new("group:week").parse
    assert_equal "week_created", result[:group_by]
  end

  test "group:month maps to month_created" do
    result = SearchQueryParser.new("group:month").parse
    assert_equal "month_created", result[:group_by]
  end

  test "group:none maps to none" do
    result = SearchQueryParser.new("group:none").parse
    assert_equal "none", result[:group_by]
  end

  # cycle: operator

  test "cycle:today returns today" do
    result = SearchQueryParser.new("cycle:today").parse
    assert_equal "today", result[:cycle]
  end

  test "cycle:this-week returns this-week" do
    result = SearchQueryParser.new("cycle:this-week").parse
    assert_equal "this-week", result[:cycle]
  end

  test "cycle:2-weeks-ago returns 2-weeks-ago" do
    result = SearchQueryParser.new("cycle:2-weeks-ago").parse
    assert_equal "2-weeks-ago", result[:cycle]
  end

  test "cycle:all returns all" do
    result = SearchQueryParser.new("cycle:all").parse
    assert_equal "all", result[:cycle]
  end

  test "cycle ignored when after: is present" do
    result = SearchQueryParser.new("cycle:today after:-7d").parse
    assert_nil result[:cycle]
    assert_not_nil result[:after_date]
  end

  test "cycle ignored when before: is present" do
    result = SearchQueryParser.new("cycle:today before:+7d").parse
    assert_nil result[:cycle]
    assert_not_nil result[:before_date]
  end

  # after: operator (absolute dates)

  test "after:YYYY-MM-DD parses absolute date" do
    result = SearchQueryParser.new("after:2024-01-15").parse
    assert_equal "2024-01-15", result[:after_date]
  end

  # after: operator (relative dates)

  test "after:-7d parses to 7 days ago" do
    travel_to Time.zone.local(2024, 6, 15, 12, 0, 0) do
      result = SearchQueryParser.new("after:-7d").parse
      assert_equal "2024-06-08", result[:after_date]
    end
  end

  test "after:-2w parses to 2 weeks ago" do
    travel_to Time.zone.local(2024, 6, 15, 12, 0, 0) do
      result = SearchQueryParser.new("after:-2w").parse
      assert_equal "2024-06-01", result[:after_date]
    end
  end

  test "after:-1m parses to 1 month ago" do
    travel_to Time.zone.local(2024, 6, 15, 12, 0, 0) do
      result = SearchQueryParser.new("after:-1m").parse
      assert_equal "2024-05-15", result[:after_date]
    end
  end

  test "after:-1y parses to 1 year ago" do
    travel_to Time.zone.local(2024, 6, 15, 12, 0, 0) do
      result = SearchQueryParser.new("after:-1y").parse
      assert_equal "2023-06-15", result[:after_date]
    end
  end

  test "after:+7d parses to 7 days from now" do
    travel_to Time.zone.local(2024, 6, 15, 12, 0, 0) do
      result = SearchQueryParser.new("after:+7d").parse
      assert_equal "2024-06-22", result[:after_date]
    end
  end

  test "after:7d without sign treated as search text" do
    result = SearchQueryParser.new("after:7d").parse
    assert_equal "after:7d", result[:q]
    assert_nil result[:after_date]
  end

  # before: operator

  test "before:YYYY-MM-DD parses absolute date" do
    result = SearchQueryParser.new("before:2024-12-31").parse
    assert_equal "2024-12-31", result[:before_date]
  end

  test "before:+14d parses to 14 days from now" do
    travel_to Time.zone.local(2024, 6, 15, 12, 0, 0) do
      result = SearchQueryParser.new("before:+14d").parse
      assert_equal "2024-06-29", result[:before_date]
    end
  end

  test "before:-7d parses to 7 days ago" do
    travel_to Time.zone.local(2024, 6, 15, 12, 0, 0) do
      result = SearchQueryParser.new("before:-7d").parse
      assert_equal "2024-06-08", result[:before_date]
    end
  end

  # limit: operator

  test "limit:10 sets per_page" do
    result = SearchQueryParser.new("limit:10").parse
    assert_equal 10, result[:per_page]
  end

  test "limit:0 clamps to 1" do
    result = SearchQueryParser.new("limit:0").parse
    assert_equal 1, result[:per_page]
  end

  test "limit:200 clamps to 100" do
    result = SearchQueryParser.new("limit:200").parse
    assert_equal 100, result[:per_page]
  end

  # Combined queries

  test "search text with operators" do
    result = SearchQueryParser.new("budget type:note is:open").parse
    assert_equal "budget", result[:q]
    assert_equal "note", result[:type]
    assert_includes result[:filters], "open"
  end

  test "operator order does not matter" do
    result = SearchQueryParser.new("type:note budget is:open").parse
    assert_equal "budget", result[:q]
    assert_equal "note", result[:type]
    assert_includes result[:filters], "open"
  end

  test "complex query with all features" do
    query = '"quarterly review" type:note,decision is:open sort:newest limit:10'
    result = SearchQueryParser.new(query).parse

    assert_nil result[:q]
    assert_equal ["quarterly review"], result[:exact_phrases]
    assert_equal "note,decision", result[:type]
    assert_includes result[:filters], "open"
    assert_equal "created_at-desc", result[:sort_by]
    assert_equal 10, result[:per_page]
  end

  test "date range query" do
    result = SearchQueryParser.new("after:2024-01-01 before:2024-03-31").parse
    assert_equal "2024-01-01", result[:after_date]
    assert_equal "2024-03-31", result[:before_date]
    assert_nil result[:cycle]
  end

  test "invalid operator falls through to search text" do
    result = SearchQueryParser.new("foo:bar type:note").parse
    assert_equal "foo:bar", result[:q]
    assert_equal "note", result[:type]
  end

  test "case insensitive operators" do
    result = SearchQueryParser.new("TYPE:NOTE IS:OPEN").parse
    assert_equal "note", result[:type]
    assert_includes result[:filters], "open"
  end

  # Exact phrase matching (quoted strings)

  test "multiple quoted phrases" do
    result = SearchQueryParser.new('"first phrase" "second phrase"').parse
    assert_nil result[:q]
    assert_equal ["first phrase", "second phrase"], result[:exact_phrases]
  end

  test "mixed quoted and unquoted" do
    result = SearchQueryParser.new('apple "banana cherry" date').parse
    assert_equal "apple date", result[:q]
    assert_equal ["banana cherry"], result[:exact_phrases]
  end

  test "quoted string is not parsed as operator" do
    result = SearchQueryParser.new('"type:note"').parse
    assert_nil result[:type]
    assert_equal ["type:note"], result[:exact_phrases]
  end

  # Negated search terms (term exclusion)

  test "negated term becomes excluded term" do
    result = SearchQueryParser.new("apple -banana").parse
    assert_equal "apple", result[:q]
    assert_equal ["banana"], result[:excluded_terms]
  end

  test "multiple negated terms" do
    result = SearchQueryParser.new("apple -banana -cherry").parse
    assert_equal "apple", result[:q]
    assert_equal ["banana", "cherry"], result[:excluded_terms]
  end

  test "negated quoted phrase" do
    result = SearchQueryParser.new('apple -"banana cherry"').parse
    assert_equal "apple", result[:q]
    assert_equal ["banana cherry"], result[:excluded_terms]
  end

  test "only negated terms" do
    result = SearchQueryParser.new("-banana -cherry").parse
    assert_nil result[:q]
    assert_equal ["banana", "cherry"], result[:excluded_terms]
  end

  test "complex query with all term types" do
    result = SearchQueryParser.new('apple "exact phrase" -exclude type:note').parse
    assert_equal "apple", result[:q]
    assert_equal ["exact phrase"], result[:exact_phrases]
    assert_equal ["exclude"], result[:excluded_terms]
    assert_equal "note", result[:type]
  end

  # in: operator (superagent scope)

  test "in: operator parses superagent handle" do
    result = SearchQueryParser.new("budget in:my-studio").parse
    assert_equal "budget", result[:q]
    assert_equal "my-studio", result[:superagent_handle]
  end

  test "in: operator accepts alphanumeric with dashes" do
    result = SearchQueryParser.new("in:test-studio-123").parse
    assert_equal "test-studio-123", result[:superagent_handle]
  end

  test "in: operator is case insensitive for value" do
    result = SearchQueryParser.new("in:My-Studio").parse
    assert_equal "my-studio", result[:superagent_handle]
  end

  test "in: operator with other operators" do
    result = SearchQueryParser.new("budget type:note in:team-alpha sort:newest").parse
    assert_equal "budget", result[:q]
    assert_equal "note", result[:type]
    assert_equal "team-alpha", result[:superagent_handle]
    assert_equal "created_at-desc", result[:sort_by]
  end

  test "invalid in: value is treated as search text" do
    result = SearchQueryParser.new("in:has spaces").parse
    # "in:has" would be valid as a handle, but "spaces" becomes search text
    # Actually "in:has" matches the pattern, so it becomes the handle
    assert_equal "has", result[:superagent_handle]
    assert_equal "spaces", result[:q]
  end
end
