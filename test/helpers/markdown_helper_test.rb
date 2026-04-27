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
end
