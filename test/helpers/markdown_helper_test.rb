require "test_helper"

class MarkdownHelperTest < ActionView::TestCase
  include MarkdownHelper

  def params
    @test_params || {}
  end

  # truncate_content

  test "truncate_content returns content unchanged when under limit" do
    result = truncate_content("Short content")
    assert_equal "Short content", result
  end

  test "truncate_content returns blank content unchanged" do
    assert_nil truncate_content(nil)
    assert_equal "", truncate_content("")
  end

  test "truncate_content returns content at exactly the limit unchanged" do
    content = "x" * 2000
    assert_equal content, truncate_content(content)
  end

  test "truncate_content truncates over-limit content" do
    content = "x" * 3000
    result = truncate_content(content)
    assert result.length <= MARKDOWN_CONTENT_TRUNCATION_LIMIT
  end

  test "truncate_content returns full content when full_text=true" do
    @test_params = { full_text: "true" }
    content = "x" * 3000
    assert_equal content, truncate_content(content)
  end

  test "truncate_content truncates at last line boundary" do
    lines = (1..100).map { |i| "Line #{i}: #{'x' * 30}" }.join("\n")
    result = truncate_content(lines)

    assert result.length <= MARKDOWN_CONTENT_TRUNCATION_LIMIT
    # Should end at a complete line, not mid-line
    assert_not result.end_with?("x\nLin")
  end

  test "truncate_content preserves complete table rows" do
    header = "| Status | Due |\n| --- | --- |"
    rows = (1..100).map { |i| "| row#{i} | 2026-04-#{format('%02d', i % 28 + 1)} |" }.join("\n")
    content = "#{header}\n#{rows}"

    result = truncate_content(content)

    assert result.length <= MARKDOWN_CONTENT_TRUNCATION_LIMIT
    result.split("\n").each do |line|
      assert line.start_with?("|"), "Expected line to start with |: #{line.truncate(40)}"
      assert line.end_with?("|"), "Expected line to end with |: #{line.truncate(40)}"
    end
  end

  # markdown_truncation_notice

  test "markdown_truncation_notice returns nil when not truncated" do
    content = "same"
    assert_nil markdown_truncation_notice(content, content, url: "/n/abc")
  end

  test "markdown_truncation_notice returns message with character counts and url" do
    original = "x" * 3000
    truncated = "x" * 1990
    notice = markdown_truncation_notice(original, truncated, url: "/n/abc")

    assert_includes notice, "showing 1990 of 3000 characters"
    assert_includes notice, "/n/abc?full_text=true"
  end

  # yaml_escape
  #
  # The frontmatter block in application.md.erb is a wire protocol the
  # agent-runner / MCP `fetch_page` consumer parses. yaml_escape is the sole
  # chokepoint that keeps user-controlled values (note title, decision question,
  # scope/query, descriptions) from breaking out of their scalar. Round-trip
  # every escaped value through a real YAML parser: whatever went in must come
  # back out unchanged, as a single scalar, injecting no keys.
  def assert_yaml_roundtrip(input)
    emitted = "title: #{yaml_escape(input)}\n"
    parsed = YAML.safe_load(emitted)
    assert_equal({ "title" => input }, parsed,
                 "#{input.inspect} did not round-trip through frontmatter")
  end

  test "yaml_escape leaves a plain value unquoted" do
    assert_equal "hello world", yaml_escape("hello world")
  end

  test "yaml_escape returns an html_safe string" do
    assert_predicate yaml_escape("plain"), :html_safe?
    assert_predicate yaml_escape("a: b"), :html_safe?
  end

  test "yaml_escape round-trips an interior newline as a single scalar" do
    # The core injection: unquoted, this newline would start new frontmatter keys.
    assert_yaml_roundtrip("pwned\ninjected_key: gotcha\nactions: []")
  end

  test "yaml_escape round-trips a value with a colon-space that would otherwise fold" do
    # Quoted but with a literal newline, YAML folds the newline into a space.
    assert_yaml_roundtrip("Ship it?\nactions: []")
  end

  test "yaml_escape round-trips tab and carriage-return control characters" do
    assert_yaml_roundtrip("a\tb\r\nc")
  end

  test "yaml_escape round-trips other control characters via \\xNN escapes" do
    assert_yaml_roundtrip("bell\aend")
    assert_yaml_roundtrip("esc\e[31mred")
    assert_yaml_roundtrip("null\x00byte")
    assert_yaml_roundtrip("del\x7Fchar")
  end

  test "yaml_escape round-trips embedded quotes and backslashes" do
    assert_yaml_roundtrip('quote " and \\ backslash')
  end

  test "yaml_escape round-trips YAML-significant leading characters and structure" do
    ["- leading dash", "@ at sign", "#comment", "*anchor", "key: value",
     "trailing space ", " leading space", "[list]", "{map}", ""].each do |input|
      assert_yaml_roundtrip(input)
    end
  end

  test "yaml_escape round-trips scalars YAML would otherwise retype to non-strings" do
    # Bare, these emit `title: true` / `title: 123` etc. and parse back as a
    # boolean / integer / null — a note literally titled "true" or "123" must
    # survive as a string through the machine-parsed frontmatter.
    ["true", "false", "yes", "no", "on", "off", "null", "~",
     "123", "-5", "1.5", ".inf", ".nan", "12:30:00"].each do |input|
      assert_yaml_roundtrip(input)
    end
  end

  test "yaml_escape leaves search-syntax scope/query values unquoted" do
    # These flow through yaml_escape as page scope/query; they parse back as
    # plain strings, so quoting them would be noise the frontmatter tests reject.
    ["visibility:public", "type:note", "list:tuned_in -subtype:comment",
     "visibility:public creator:@alice"].each do |input|
      assert_equal input, yaml_escape(input), "#{input.inspect} should stay unquoted"
    end
  end
end
