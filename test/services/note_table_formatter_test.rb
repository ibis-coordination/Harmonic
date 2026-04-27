require "test_helper"

class NoteTableFormatterTest < ActiveSupport::TestCase
  test "generates markdown table from table_data" do
    table_data = {
      "columns" => [
        { "name" => "Status", "type" => "text" },
        { "name" => "Due", "type" => "date" },
      ],
      "rows" => [
        { "_id" => "abc1", "Status" => "done", "Due" => "2026-04-20" },
        { "_id" => "def2", "Status" => "in_progress", "Due" => "2026-04-28" },
      ],
    }

    result = NoteTableFormatter.to_markdown(table_data)

    assert_includes result, "| Status | Due |"
    assert_includes result, "| --- | --- |"
    assert_includes result, "| done | 2026-04-20 |"
    assert_includes result, "| in_progress | 2026-04-28 |"
  end

  test "prepends description before table" do
    table_data = {
      "description" => "Task tracker for Q2.",
      "columns" => [{ "name" => "Task", "type" => "text" }],
      "rows" => [{ "_id" => "abc1", "Task" => "Ship it" }],
    }

    result = NoteTableFormatter.to_markdown(table_data)

    assert result.start_with?("Task tracker for Q2.\n")
    assert_includes result, "| Task |"
    assert_includes result, "| Ship it |"
  end

  test "returns only description when no columns" do
    table_data = {
      "description" => "Empty table",
      "columns" => [],
      "rows" => [],
    }

    result = NoteTableFormatter.to_markdown(table_data)
    assert_equal "Empty table\n", result
  end

  test "returns empty string when no columns and no description" do
    result = NoteTableFormatter.to_markdown({ "columns" => [], "rows" => [] })
    assert_equal "", result
  end

  test "escapes pipe characters in cell values" do
    table_data = {
      "columns" => [{ "name" => "Value", "type" => "text" }],
      "rows" => [{ "_id" => "abc1", "Value" => "a|b|c" }],
    }

    result = NoteTableFormatter.to_markdown(table_data)

    assert_includes result, 'a\|b\|c'
    # Verify the table structure isn't broken (should only have the expected pipes)
    data_row = result.split("\n").last
    # Data row should have exactly 2 unescaped pipes (start and end)
    unescaped_pipes = data_row.gsub('\\|', "").count("|")
    assert_equal 2, unescaped_pipes
  end

  test "escapes pipe characters in column names" do
    table_data = {
      "columns" => [{ "name" => "Name|Value", "type" => "text" }],
      "rows" => [],
    }

    result = NoteTableFormatter.to_markdown(table_data)
    assert_includes result, 'Name\|Value'
  end

  test "handles nil cell values as blank" do
    table_data = {
      "columns" => [
        { "name" => "A", "type" => "text" },
        { "name" => "B", "type" => "text" },
      ],
      "rows" => [{ "_id" => "abc1", "A" => "hello", "B" => nil }],
    }

    result = NoteTableFormatter.to_markdown(table_data)
    assert_includes result, "| hello |  |"
  end

  test "handles empty string cell values" do
    table_data = {
      "columns" => [{ "name" => "A", "type" => "text" }],
      "rows" => [{ "_id" => "abc1", "A" => "" }],
    }

    result = NoteTableFormatter.to_markdown(table_data)
    assert_includes result, "|  |"
  end

  test "strips null bytes from values" do
    table_data = {
      "columns" => [{ "name" => "A", "type" => "text" }],
      "rows" => [{ "_id" => "abc1", "A" => "hello\x00world" }],
    }

    result = NoteTableFormatter.to_markdown(table_data)
    assert_includes result, "helloworld"
    refute_includes result, "\x00"
  end

  test "strips control characters from values" do
    table_data = {
      "columns" => [{ "name" => "A", "type" => "text" }],
      "rows" => [{ "_id" => "abc1", "A" => "hello\x01\x02world" }],
    }

    result = NoteTableFormatter.to_markdown(table_data)
    assert_includes result, "helloworld"
  end

  test "preserves script tags as literal text (sanitized by Redcarpet on render)" do
    table_data = {
      "columns" => [{ "name" => "Content", "type" => "text" }],
      "rows" => [{ "_id" => "abc1", "Content" => "<script>alert('xss')</script>" }],
    }

    result = NoteTableFormatter.to_markdown(table_data)
    assert_includes result, "<script>alert('xss')</script>"
  end

  test "preserves markdown syntax in cell values" do
    table_data = {
      "columns" => [{ "name" => "Note", "type" => "text" }],
      "rows" => [{ "_id" => "abc1", "Note" => "**bold** and [link](http://example.com)" }],
    }

    result = NoteTableFormatter.to_markdown(table_data)
    assert_includes result, "**bold** and [link](http://example.com)"
  end
end
