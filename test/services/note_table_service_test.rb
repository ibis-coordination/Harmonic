require "test_helper"

class NoteTableServiceTest < ActiveSupport::TestCase
  def create_table_note(columns: nil, description: nil)
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)
    columns ||= [
      { "name" => "Status", "type" => "text" },
      { "name" => "Due", "type" => "date" },
    ]

    Note.create!(
      tenant: tenant,
      collective: collective,
      created_by: user,
      updated_by: user,
      subtype: "table",
      title: "Test Table",
      text: "",
      table_data: {
        "description" => description,
        "columns" => columns,
        "rows" => [],
      },
    )
  end

  # Accessors

  test "accessors return columns, rows, column_names, description" do
    note = create_table_note(description: "My table")
    table = NoteTableService.new(note)

    assert_equal "My table", table.description
    assert_equal 2, table.columns.length
    assert_equal 0, table.rows.length
    assert_equal %w[Status Due], table.column_names
  end

  test "raises if note is not a table" do
    tenant = create_tenant
    user = create_user
    collective = create_collective(tenant: tenant, created_by: user)
    note = Note.create!(tenant: tenant, collective: collective, created_by: user, updated_by: user, text: "plain note")

    assert_raises(RuntimeError, "Not a table note") do
      NoteTableService.new(note)
    end
  end

  # Row mutations

  test "add_row! appends a row and regenerates text" do
    note = create_table_note
    table = NoteTableService.new(note)

    row = table.add_row!({ "Status" => "done", "Due" => "2026-04-20" }, created_by: note.created_by)

    assert_equal 1, table.rows.length
    assert row["_id"].present?
    assert_equal "done", row["Status"]
    assert_includes note.text, "done"
    assert_includes note.text, "2026-04-20"
  end

  test "update_row! updates specific cells" do
    note = create_table_note
    table = NoteTableService.new(note)
    row = table.add_row!({ "Status" => "pending", "Due" => "2026-04-20" }, created_by: note.created_by)

    updated = table.update_row!(row["_id"], { "Status" => "done" })

    assert_equal "done", updated["Status"]
    assert_equal "2026-04-20", updated["Due"]
    assert_includes note.text, "done"
  end

  test "update_row! raises for unknown row_id" do
    note = create_table_note
    table = NoteTableService.new(note)

    assert_raises(RuntimeError) do
      table.update_row!("nonexistent", { "Status" => "done" })
    end
  end

  test "delete_row! removes a row" do
    note = create_table_note
    table = NoteTableService.new(note)
    row = table.add_row!({ "Status" => "done", "Due" => "2026-04-20" }, created_by: note.created_by)

    table.delete_row!(row["_id"])

    assert_equal 0, table.rows.length
    refute_includes note.text, "done"
  end

  test "delete_row! raises for unknown row_id" do
    note = create_table_note
    table = NoteTableService.new(note)

    assert_raises(RuntimeError) do
      table.delete_row!("nonexistent")
    end
  end

  # Schema mutations

  test "define_columns! sets columns on empty table" do
    note = create_table_note(columns: [])
    table = NoteTableService.new(note)

    table.define_columns!([
      { "name" => "Name", "type" => "text" },
      { "name" => "Age", "type" => "number" },
    ])

    assert_equal 2, table.columns.length
    assert_equal %w[Name Age], table.column_names
  end

  test "define_columns! raises when rows exist and columns already defined" do
    note = create_table_note
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Due" => "2026-04-20" }, created_by: note.created_by)

    assert_raises(RuntimeError, "Cannot replace columns when rows exist") do
      table.define_columns!([{ "name" => "New", "type" => "text" }])
    end
  end

  test "add_column! adds a column" do
    note = create_table_note
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Due" => "2026-04-20" }, created_by: note.created_by)

    table.add_column!("Priority", "text")

    assert_equal 3, table.columns.length
    assert_includes table.column_names, "Priority"
    assert_includes note.text, "Priority"
  end

  test "remove_column! removes column and its values" do
    note = create_table_note
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Due" => "2026-04-20" }, created_by: note.created_by)

    table.remove_column!("Due")

    assert_equal 1, table.columns.length
    refute_includes table.column_names, "Due"
    refute_includes note.text, "2026-04-20"
  end

  test "remove_column! raises for unknown column" do
    note = create_table_note
    table = NoteTableService.new(note)

    assert_raises(RuntimeError) do
      table.remove_column!("Nonexistent")
    end
  end

  # Description

  test "update_description! updates description in derived text" do
    note = create_table_note
    table = NoteTableService.new(note)
    table.update_description!("Updated description")

    assert_equal "Updated description", table.description
    assert note.text.start_with?("Updated description")
  end

  # Derived text

  test "derived text includes description and table" do
    note = create_table_note(description: "My task list")
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Due" => "2026-04-20" }, created_by: note.created_by)

    assert note.text.start_with?("My task list")
    assert_includes note.text, "| Status | Due |"
    assert_includes note.text, "| done | 2026-04-20 |"
  end

  # Query

  test "query_rows filters by equality" do
    note = create_table_note
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Due" => "2026-04-20" }, created_by: note.created_by)
    table.add_row!({ "Status" => "pending", "Due" => "2026-04-25" }, created_by: note.created_by)
    table.add_row!({ "Status" => "done", "Due" => "2026-04-15" }, created_by: note.created_by)

    result = table.query_rows(where: { "Status" => "done" })

    assert_equal 2, result[:total]
    assert_equal 2, result[:rows].length
    assert result[:rows].all? { |r| r["Status"] == "done" }
  end

  test "query_rows sorts by column" do
    note = create_table_note
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "b", "Due" => "2026-04-20" }, created_by: note.created_by)
    table.add_row!({ "Status" => "a", "Due" => "2026-04-25" }, created_by: note.created_by)
    table.add_row!({ "Status" => "c", "Due" => "2026-04-15" }, created_by: note.created_by)

    result = table.query_rows(order_by: "Status", order: "asc")
    assert_equal %w[a b c], result[:rows].map { |r| r["Status"] }

    result = table.query_rows(order_by: "Status", order: "desc")
    assert_equal %w[c b a], result[:rows].map { |r| r["Status"] }
  end

  test "query_rows paginates with limit and offset" do
    note = create_table_note
    table = NoteTableService.new(note)
    5.times { |i| table.add_row!({ "Status" => "item#{i}", "Due" => "2026-04-2#{i}" }, created_by: note.created_by) }

    result = table.query_rows(limit: 2, offset: 1)

    assert_equal 5, result[:total]
    assert_equal 2, result[:rows].length
  end

  # Batch operations

  test "batch_update! saves once for multiple mutations" do
    note = create_table_note
    table = NoteTableService.new(note)

    assert_equal 1, note.note_history_events.count # just the "create" event

    table.batch_update! do |t|
      t.add_row!({ "Status" => "a", "Due" => "2026-04-20" }, created_by: note.created_by)
      t.add_row!({ "Status" => "b", "Due" => "2026-04-21" }, created_by: note.created_by)
      t.add_row!({ "Status" => "c", "Due" => "2026-04-22" }, created_by: note.created_by)
    end

    assert_equal 3, table.rows.length
    assert_equal 1, note.note_history_events.where(event_type: "update").count
    assert_equal 2, note.note_history_events.count
    assert_includes note.text, "| a |"
    assert_includes note.text, "| c |"
  end

  # Aggregation

  test "summarize count returns row count" do
    note = create_table_note(columns: [{ "name" => "Amount", "type" => "number" }])
    table = NoteTableService.new(note)
    3.times { |i| table.add_row!({ "Amount" => (i + 1).to_s }, created_by: note.created_by) }

    assert_equal 3, table.summarize(operation: "count")
  end

  test "summarize sum adds numeric values" do
    note = create_table_note(columns: [{ "name" => "Amount", "type" => "number" }])
    table = NoteTableService.new(note)
    table.add_row!({ "Amount" => "10" }, created_by: note.created_by)
    table.add_row!({ "Amount" => "20" }, created_by: note.created_by)
    table.add_row!({ "Amount" => "30" }, created_by: note.created_by)

    assert_equal 60.0, table.summarize(operation: "sum", column: "Amount")
  end

  test "summarize average computes mean" do
    note = create_table_note(columns: [{ "name" => "Amount", "type" => "number" }])
    table = NoteTableService.new(note)
    table.add_row!({ "Amount" => "10" }, created_by: note.created_by)
    table.add_row!({ "Amount" => "20" }, created_by: note.created_by)

    assert_equal 15.0, table.summarize(operation: "average", column: "Amount")
  end

  test "summarize with where filter" do
    note = create_table_note(columns: [
      { "name" => "Status", "type" => "text" },
      { "name" => "Amount", "type" => "number" },
    ])
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "active", "Amount" => "10" }, created_by: note.created_by)
    table.add_row!({ "Status" => "active", "Amount" => "20" }, created_by: note.created_by)
    table.add_row!({ "Status" => "closed", "Amount" => "100" }, created_by: note.created_by)

    result = table.summarize(operation: "sum", column: "Amount", where: { "Status" => "active" })
    assert_equal 30.0, result
  end
end
