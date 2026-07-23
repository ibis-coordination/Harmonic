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

  # markdown_frontmatter_block
  #
  # The frontmatter is a wire protocol MarkdownUiService, the agent-runner, and
  # external clients parse with a standard YAML parser, so it is emitted with a
  # standard YAML emitter (Psych). The property that matters: whatever value goes
  # in — including adversarial titles/queries — parses back out as the identical
  # string, injecting no keys and never silently retyped. Parse the emitted block
  # the same way the consumer does (strip the fences, YAML.safe_load the body).
  def frontmatter_of(block)
    body = block.delete_prefix("---\n").delete_suffix("\n---")
    YAML.safe_load(body, permitted_classes: [Time, Symbol])
  end

  def build_block(**overrides)
    markdown_frontmatter_block(**{
      app: "Harmonic", host: "t.example.com", path: "/x",
      title: "Hello", timestamp: Time.utc(2026, 7, 23, 12, 0, 0)
    }.merge(overrides))
  end

  test "markdown_frontmatter_block emits a fenced, html_safe block that parses" do
    block = build_block
    assert_predicate block, :html_safe?
    assert block.start_with?("---\n"), "must open with a --- fence"
    assert block.end_with?("\n---"), "must close with a --- fence"
    fm = frontmatter_of(block)
    assert_equal "Harmonic", fm["app"]
    assert_equal "t.example.com", fm["host"]
    assert_equal "/x", fm["path"]
    assert_equal "Hello", fm["title"]
  end

  test "markdown_frontmatter_block omits scope/query/actions when blank" do
    fm = frontmatter_of(build_block(scope: nil, query: "", actions: []))
    assert_not fm.key?("scope")
    assert_not fm.key?("query")
    assert_not fm.key?("actions")
  end

  test "markdown_frontmatter_block includes scope and query when present" do
    fm = frontmatter_of(build_block(scope: "visibility:public", query: "type:note"))
    assert_equal "visibility:public", fm["scope"]
    assert_equal "type:note", fm["query"]
  end

  # A title/query containing a newline, control chars, quotes, or YAML structure
  # must round-trip as one scalar and never inject a key — the injection the whole
  # refactor removes. Psych is the escaper now, so this exercises the contract end
  # to end rather than a hand-rolled helper.
  [
    "pwned\ninjected_key: gotcha\nactions: []",
    "Ship it?\nactions: []",
    "a\tb\r\nc",
    "bell\aend",
    "esc\e[31mred",
    "null\x00byte",
    "del\x7Fchar",
    'quote " and \\ backslash',
    "- leading dash",
    "@ at sign",
    "#comment",
    "key: value",
    " leading space",
    "trailing space ",
    "",
  ].each do |payload|
    test "markdown_frontmatter_block round-trips title #{payload.inspect} as a string" do
      fm = frontmatter_of(build_block(title: payload))
      assert_equal payload, fm["title"]
      assert_equal ["app", "host", "path", "title", "timestamp"], fm.keys,
                   "payload must not inject or reorder keys"
    end
  end

  # Bare true/123/null etc. must survive as strings, not be retyped to
  # boolean/integer/null by the parser.
  ["true", "false", "yes", "no", "null", "~", "123", "-5", "1.5", "12:30:00"].each do |payload|
    test "markdown_frontmatter_block keeps title #{payload.inspect} a string, not retyped" do
      fm = frontmatter_of(build_block(title: payload))
      assert_equal payload, fm["title"]
      assert_kind_of String, fm["title"]
    end
  end

  test "markdown_frontmatter_block shapes actions and omits empty params/description" do
    actions = [
      { name: "create_note", visibility: "public", description: "Create a note",
        params: [{ name: "body", type: "string", required: true, description: "the text" },
                 { name: "title", type: "string", required: false, description: nil }] },
      { name: "vote", visibility: "shared", description: "Cast a vote", params: [] },
    ]
    fm = frontmatter_of(build_block(actions: actions))

    assert_equal %w[create_note vote], fm["actions"].map { |a| a["name"] }
    create = fm["actions"][0]
    assert_equal "public", create["visibility"]
    assert_equal({ "name" => "body", "type" => "string", "required" => true, "description" => "the text" },
                 create["params"][0])
    # nil param description is omitted, not emitted as null.
    assert_not create["params"][1].key?("description")
    # An action with no params omits the key entirely.
    assert_not fm["actions"][1].key?("params")
  end

  test "markdown_frontmatter_block round-trips an action description with YAML structure" do
    actions = [{ name: "x", visibility: "public", description: "Do this: then #that", params: [] }]
    fm = frontmatter_of(build_block(actions: actions))
    assert_equal "Do this: then #that", fm["actions"][0]["description"]
  end
end
