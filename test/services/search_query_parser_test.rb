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

  test "-type:note excludes notes" do
    result = SearchQueryParser.new("-type:note").parse
    assert_equal ["note"], result[:exclude_types]
    assert_nil result[:type]
  end

  test "-type:note,decision excludes multiple types" do
    result = SearchQueryParser.new("-type:note,decision").parse
    assert_equal ["note", "decision"], result[:exclude_types]
    assert_nil result[:type]
  end

  test "type:decision -type:note works together" do
    result = SearchQueryParser.new("type:decision -type:note").parse
    assert_equal "decision", result[:type]
    assert_equal ["note"], result[:exclude_types]
  end

  # status: operator

  test "status:open sets open status" do
    result = SearchQueryParser.new("status:open").parse
    assert_equal "open", result[:status]
  end

  test "status:closed sets closed status" do
    result = SearchQueryParser.new("status:closed").parse
    assert_equal "closed", result[:status]
  end

  test "-status:open sets closed status" do
    result = SearchQueryParser.new("-status:open").parse
    assert_equal "closed", result[:status]
  end

  test "-status:closed sets open status" do
    result = SearchQueryParser.new("-status:closed").parse
    assert_equal "open", result[:status]
  end

  # subtype: operator

  test "-subtype:comment excludes comments" do
    result = SearchQueryParser.new("-subtype:comment").parse
    assert_equal ["comment"], result[:exclude_subtypes]
  end

  # creator: operator

  test "creator:@alice sets creator handles" do
    result = SearchQueryParser.new("creator:@alice").parse
    assert_equal ["alice"], result[:creator_handles]
  end

  test "creator:@alice,@bob sets multiple creator handles" do
    result = SearchQueryParser.new("creator:@alice,@bob").parse
    assert_equal ["alice", "bob"], result[:creator_handles]
  end

  test "-creator:@alice sets exclude creator handles" do
    result = SearchQueryParser.new("-creator:@alice").parse
    assert_equal ["alice"], result[:exclude_creator_handles]
  end

  test "creator:alice works without @ prefix" do
    result = SearchQueryParser.new("creator:alice").parse
    assert_equal ["alice"], result[:creator_handles]
  end

  test "creator:alice,bob works without @ prefix for multiple handles" do
    result = SearchQueryParser.new("creator:alice,bob").parse
    assert_equal ["alice", "bob"], result[:creator_handles]
  end

  test "creator:@alice,bob works with mixed @ prefix usage" do
    result = SearchQueryParser.new("creator:@alice,bob").parse
    assert_equal ["alice", "bob"], result[:creator_handles]
  end

  # read-by: operator

  test "read-by:@alice sets read_by handles" do
    result = SearchQueryParser.new("read-by:@alice").parse
    assert_equal ["alice"], result[:read_by_handles]
  end

  test "-read-by:@alice sets exclude read_by handles" do
    result = SearchQueryParser.new("-read-by:@alice").parse
    assert_equal ["alice"], result[:exclude_read_by_handles]
  end

  # voter: operator

  test "voter:@alice sets voter handles" do
    result = SearchQueryParser.new("voter:@alice").parse
    assert_equal ["alice"], result[:voter_handles]
  end

  test "-voter:@alice sets exclude voter handles" do
    result = SearchQueryParser.new("-voter:@alice").parse
    assert_equal ["alice"], result[:exclude_voter_handles]
  end

  # participant: operator

  test "participant:@alice sets participant handles" do
    result = SearchQueryParser.new("participant:@alice").parse
    assert_equal ["alice"], result[:participant_handles]
  end

  test "-participant:@alice sets exclude participant handles" do
    result = SearchQueryParser.new("-participant:@alice").parse
    assert_equal ["alice"], result[:exclude_participant_handles]
  end

  # mentions: operator

  test "mentions:@alice sets mentions handles" do
    result = SearchQueryParser.new("mentions:@alice").parse
    assert_equal ["alice"], result[:mentions_handles]
  end

  test "-mentions:@alice sets exclude mentions handles" do
    result = SearchQueryParser.new("-mentions:@alice").parse
    assert_equal ["alice"], result[:exclude_mentions_handles]
  end

  # replying-to: operator

  test "replying-to:@alice sets replying_to handles" do
    result = SearchQueryParser.new("replying-to:@alice").parse
    assert_equal ["alice"], result[:replying_to_handles]
  end

  # min/max count operators

  test "min-backlinks:1 sets min_backlinks" do
    result = SearchQueryParser.new("min-backlinks:1").parse
    assert_equal 1, result[:min_backlinks]
  end

  test "max-backlinks:10 sets max_backlinks" do
    result = SearchQueryParser.new("max-backlinks:10").parse
    assert_equal 10, result[:max_backlinks]
  end

  test "min-links:1 sets min_links" do
    result = SearchQueryParser.new("min-links:1").parse
    assert_equal 1, result[:min_links]
  end

  test "min-comments:5 sets min_comments" do
    result = SearchQueryParser.new("min-comments:5").parse
    assert_equal 5, result[:min_comments]
  end

  test "min-readers:10 sets min_readers" do
    result = SearchQueryParser.new("min-readers:10").parse
    assert_equal 10, result[:min_readers]
  end

  test "min-voters:3 sets min_voters" do
    result = SearchQueryParser.new("min-voters:3").parse
    assert_equal 3, result[:min_voters]
  end

  test "min-participants:2 sets min_participants" do
    result = SearchQueryParser.new("min-participants:2").parse
    assert_equal 2, result[:min_participants]
  end

  # critical-mass-achieved: operator

  test "critical-mass-achieved:true sets critical_mass_achieved to true" do
    result = SearchQueryParser.new("critical-mass-achieved:true").parse
    assert_equal true, result[:critical_mass_achieved]
  end

  test "critical-mass-achieved:false sets critical_mass_achieved to false" do
    result = SearchQueryParser.new("critical-mass-achieved:false").parse
    assert_equal false, result[:critical_mass_achieved]
  end

  # studio: and scene: operators

  test "studio:my-studio sets studio_handle" do
    result = SearchQueryParser.new("studio:my-studio").parse
    assert_equal "my-studio", result[:studio_handle]
  end

  test "scene:planning sets scene_handle" do
    result = SearchQueryParser.new("scene:planning").parse
    assert_equal "planning", result[:scene_handle]
  end

  test "studio: operator accepts alphanumeric with dashes" do
    result = SearchQueryParser.new("studio:test-studio-123").parse
    assert_equal "test-studio-123", result[:studio_handle]
  end

  test "studio: operator is case insensitive for value" do
    result = SearchQueryParser.new("studio:My-Studio").parse
    assert_equal "my-studio", result[:studio_handle]
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
    result = SearchQueryParser.new("budget type:note status:open").parse
    assert_equal "budget", result[:q]
    assert_equal "note", result[:type]
    assert_equal "open", result[:status]
  end

  test "operator order does not matter" do
    result = SearchQueryParser.new("type:note budget status:open").parse
    assert_equal "budget", result[:q]
    assert_equal "note", result[:type]
    assert_equal "open", result[:status]
  end

  test "complex query with all features" do
    query = '"quarterly review" type:note,decision status:open sort:newest limit:10'
    result = SearchQueryParser.new(query).parse

    assert_nil result[:q]
    assert_equal ["quarterly review"], result[:exact_phrases]
    assert_equal "note,decision", result[:type]
    assert_equal "open", result[:status]
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
    result = SearchQueryParser.new("TYPE:NOTE STATUS:OPEN").parse
    assert_equal "note", result[:type]
    assert_equal "open", result[:status]
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

  # Studio operator with other operators

  test "studio: operator with other operators" do
    result = SearchQueryParser.new("budget type:note studio:team-alpha sort:newest").parse
    assert_equal "budget", result[:q]
    assert_equal "note", result[:type]
    assert_equal "team-alpha", result[:studio_handle]
    assert_equal "created_at-desc", result[:sort_by]
  end

  test "invalid studio: value is treated as search text" do
    result = SearchQueryParser.new("studio:has spaces").parse
    # "studio:has" would be valid as a handle, but "spaces" becomes search text
    assert_equal "has", result[:studio_handle]
    assert_equal "spaces", result[:q]
  end
end
