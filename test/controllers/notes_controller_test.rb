require "test_helper"

class NotesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  # === Unauthenticated Access Tests ===

  test "unauthenticated user is redirected from new note form" do
    get "/collectives/#{@collective.handle}/note"
    assert_response :redirect
  end

  # === New Note Tests ===

  test "authenticated user can access new note form" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/note"
    assert_response :success
  end

  test "new note form shows members-only visibility hint for non-main collective" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/note"
    assert_response :success
    assert_select ".pulse-visibility-hint", /Only members of this collective/
  end

  test "new note form shows publicly visible hint for main collective" do
    sign_in_as(@user, tenant: @tenant)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user) unless main_collective.collective_members.exists?(user: @user)
    get "/note"
    assert_response :success
    assert_select ".pulse-visibility-hint", /publicly visible/
  end

  test "new note markdown shows members-only visibility for non-main collective" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/note", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/Only members of this collective/, response.body)
  end

  test "new note markdown shows publicly visible for main collective" do
    sign_in_as(@user, tenant: @tenant)
    main_collective = @tenant.main_collective
    main_collective.add_user!(@user) unless main_collective.collective_members.exists?(user: @user)
    get "/note", headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert_match(/publicly visible/, response.body)
  end

  # === Create Note Tests ===

  test "authenticated user can create a note" do
    sign_in_as(@user, tenant: @tenant)

    assert_difference "Note.count", 1 do
      post "/collectives/#{@collective.handle}/note", params: {
        note: {
          title: "Test Note Title",
          text: "This is the note content"
        }
      }
    end

    note = Note.last
    assert_equal "Test Note Title", note.title
    assert_equal "This is the note content", note.text
    assert_equal @user, note.created_by
    assert_response :redirect
  end

  # === Show Note Tests ===

  test "authenticated user can view a note" do
    sign_in_as(@user, tenant: @tenant)

    # Create note in thread context
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}"
    assert_response :success
  end

  test "returns 404 for non-existent note" do
    sign_in_as(@user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/n/nonexist",
        headers: { "HTTP_HOST" => "#{@tenant.subdomain}.#{ENV['HOSTNAME']}" }
    assert_response :not_found
  end

  # === Edit Note Tests ===

  test "note creator can access edit form" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}/edit"
    assert_response :success
  end

  test "non-creator cannot access edit form" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,  # Created by @user
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(other_user, tenant: @tenant)
    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}/edit"
    assert_response :forbidden
  end

  # === Update Note Tests ===

  test "note creator can update note" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Original Title",
      text: "Original content",
      deadline: Time.current + 1.week
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # Update uses POST to /n/:note_id/edit
    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/edit", params: {
      note: {
        title: "Updated Title",
        text: "Updated content"
      }
    }

    note.reload
    assert_equal "Updated Title", note.title
    assert_equal "Updated content", note.text
    assert_response :redirect
  end

  test "non-creator cannot update note" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Original Title",
      text: "Original content",
      deadline: Time.current + 1.week
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    sign_in_as(other_user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/edit", params: {
      note: {
        title: "Hacked Title"
      }
    }

    assert_response :forbidden
    note.reload
    assert_equal "Original Title", note.title
  end

  # === History Tests ===

  test "authenticated user can view note history" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}/history.html"
    assert_response :success
  end

  # === Comments API Tests ===

  test "create_comment returns JSON response" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    initial_count = Note.unscoped.count
    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/comments",
      params: { text: "This is a test comment" },
      headers: { "Accept" => "application/json" }

    assert_response :success, "Expected success but got #{response.status}: #{response.body}"
    json_response = JSON.parse(response.body)
    assert json_response["success"], "Response: #{json_response}"
    assert json_response["comment_id"].present?, "Response: #{json_response}"
    assert_equal initial_count + 1, Note.unscoped.count, "Note count should have increased by 1"
  end

  test "comments_partial returns HTML" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )

    # Create a comment on the note
    Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      text: "Test comment",
      commentable: note
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}/comments.html"

    assert_response :success
    assert_includes response.body, "pulse-comments-list"
    assert_includes response.body, "Test comment"
  end

  test "confirm_read returns JSON with confirmed_reads count" do
    sign_in_as(@user, tenant: @tenant)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/confirm_read",
      headers: { "Accept" => "application/json" }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert json_response["success"]
    assert_equal 1, json_response["confirmed_reads"]
  end

  test "confirm_read increments count for multiple users" do
    other_user = create_user(name: "Other User")
    @tenant.add_user!(other_user)
    @collective.add_user!(other_user)

    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Test Note",
      text: "Test content",
      deadline: Time.current + 1.week
    )
    Collective.clear_thread_scope
    Tenant.clear_thread_scope

    # First user confirms
    sign_in_as(@user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/confirm_read",
      headers: { "Accept" => "application/json" }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 1, json_response["confirmed_reads"]

    # Second user confirms
    sign_in_as(other_user, tenant: @tenant)
    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/confirm_read",
      headers: { "Accept" => "application/json" }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 2, json_response["confirmed_reads"]
  end

  # === Table Note Creation Tests ===

  test "creating a table note via form" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/note",
      params: {
        subtype: "table",
        title: "My Table",
        table_description: "Tracks tasks",
        columns: {
          "0" => { name: "Status", type: "text" },
          "1" => { name: "Due", type: "date" },
        },
      }

    assert_response :redirect
    note = Note.last
    assert_equal "table", note.subtype
    assert_equal "My Table", note.title
    assert_equal "Tracks tasks", note.table_data["description"]
    assert_equal 2, note.table_data["columns"].length
    assert_equal "Status", note.table_data["columns"].first["name"]
  end

  test "creating a table note skips empty column names" do
    sign_in_as(@user, tenant: @tenant)

    post "/collectives/#{@collective.handle}/note",
      params: {
        subtype: "table",
        title: "Sparse Table",
        columns: {
          "0" => { name: "Keep", type: "text" },
          "1" => { name: "", type: "text" },
        },
      }

    assert_response :redirect
    note = Note.last
    assert_equal 1, note.table_data["columns"].length
    assert_equal "Keep", note.table_data["columns"].first["name"]
  end

  # === Table Note Show Page Tests ===

  test "table note show page renders HTML table" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Due" => "2026-05-01" }, created_by: @user)

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}"

    assert_response :success
    assert_select "table.pulse-table"
    assert_select "th", text: /Status/
    assert_select "td", text: "done"
    assert_select ".pulse-resource-type-label", text: /Table/
  end

  # === Table Note Action Tests ===

  def create_table_note
    Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      subtype: "table",
      title: "Test Table",
      text: "",
      table_data: {
        "columns" => [
          { "name" => "Status", "type" => "text" },
          { "name" => "Due", "type" => "date" },
        ],
        "rows" => [],
      },
    )
  end

  test "add_row via HTML form redirects back to note" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/add_row",
      params: { values: { "Status" => "done", "Due" => "2026-05-01" } }

    assert_response :redirect
    assert_redirected_to note.path
    note.reload
    assert_equal 1, note.table_data["rows"].length
  end

  test "delete_row via HTML form redirects back to note" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note
    table = NoteTableService.new(note)
    row = table.add_row!({ "Status" => "done", "Due" => "2026-05-01" }, created_by: @user)

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/delete_row",
      params: { row_id: row["_id"] }

    assert_response :redirect
    assert_redirected_to note.path
    note.reload
    assert_equal 0, note.table_data["rows"].length
  end

  test "add_row action adds a row to table note" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/add_row",
      params: { values: { "Status" => "done", "Due" => "2026-05-01" } },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    note.reload
    assert_equal 1, note.table_data["rows"].length
    assert_equal "done", note.table_data["rows"].first["Status"]
  end

  test "update_row action updates a row in table note" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note
    table = NoteTableService.new(note)
    row = table.add_row!({ "Status" => "pending", "Due" => "2026-05-01" }, created_by: @user)

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/update_row",
      params: { row_id: row["_id"], values: { "Status" => "done" } },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    note.reload
    assert_equal "done", note.table_data["rows"].first["Status"]
  end

  test "delete_row action removes a row from table note" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note
    table = NoteTableService.new(note)
    row = table.add_row!({ "Status" => "done", "Due" => "2026-05-01" }, created_by: @user)

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/delete_row",
      params: { row_id: row["_id"] },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    note.reload
    assert_equal 0, note.table_data["rows"].length
  end

  test "query_rows action returns filtered results" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Due" => "2026-05-01" }, created_by: @user)
    table.add_row!({ "Status" => "pending", "Due" => "2026-05-02" }, created_by: @user)

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/query_rows",
      params: { where: { "Status" => "done" } },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_includes response.body, "1 rows match"
    assert_includes response.body, "done"
    refute_includes response.body, "pending"
  end

  test "summarize action returns aggregation result" do
    sign_in_as(@user, tenant: @tenant)
    note = Note.create!(
      tenant: @tenant, collective: @collective, created_by: @user, updated_by: @user,
      subtype: "table", title: "Numbers", text: "",
      table_data: { "columns" => [{ "name" => "Amount", "type" => "number" }], "rows" => [] },
    )
    table = NoteTableService.new(note)
    table.add_row!({ "Amount" => "10" }, created_by: @user)
    table.add_row!({ "Amount" => "20" }, created_by: @user)

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/summarize",
      params: { operation: "sum", column: "Amount" },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_includes response.body, "30.0"
  end

  test "add_table_column action adds a column" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/add_table_column",
      params: { name: "Priority", type: "text" },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    note.reload
    assert_equal 3, note.table_data["columns"].length
  end

  test "remove_table_column action removes a column" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/remove_table_column",
      params: { name: "Due" },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    note.reload
    assert_equal 1, note.table_data["columns"].length
  end

  test "update_table_description action updates description" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/update_table_description",
      params: { description: "New description" },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    note.reload
    assert_equal "New description", note.table_data["description"]
  end

  test "batch_table_update applies multiple operations in one save" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/batch_table_update",
      params: {
        operations: [
          { action: "add_row", values: { "Status" => "a", "Due" => "2026-05-01" } },
          { action: "add_row", values: { "Status" => "b", "Due" => "2026-05-02" } },
          { action: "add_row", values: { "Status" => "c", "Due" => "2026-05-03" } },
        ],
      },
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_includes response.body, "3 operations applied"
    note.reload
    assert_equal 3, note.table_data["rows"].length
    # Batch should create only 1 update history event
    assert_equal 1, note.note_history_events.where(event_type: "update").count
  end

  test "table note markdown view includes table actions in available actions" do
    sign_in_as(@user, tenant: @tenant)
    note = create_table_note

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}",
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    assert_includes response.body, "add_row"
    assert_includes response.body, "update_row"
    assert_includes response.body, "delete_row"
    assert_includes response.body, "query_rows"
    assert_includes response.body, "summarize"
    assert_includes response.body, "batch_table_update"
  end

  test "regular note markdown view does not include table actions" do
    sign_in_as(@user, tenant: @tenant)
    note = Note.create!(
      tenant: @tenant, collective: @collective, created_by: @user, updated_by: @user,
      text: "Regular note",
    )

    get "/collectives/#{@collective.handle}/n/#{note.truncated_id}",
      headers: { "Accept" => "text/markdown" }

    assert_response :success
    refute_includes response.body, "add_row"
    refute_includes response.body, "query_rows"
    refute_includes response.body, "batch_table_update"
    # Should still have standard note actions
    assert_includes response.body, "confirm_read"
  end

  test "table actions are not available on non-table notes" do
    sign_in_as(@user, tenant: @tenant)
    note = Note.create!(
      tenant: @tenant, collective: @collective, created_by: @user, updated_by: @user,
      text: "Regular note",
    )

    post "/collectives/#{@collective.handle}/n/#{note.truncated_id}/actions/add_row",
      params: { values: { "Col" => "val" } },
      headers: { "Accept" => "text/markdown" }

    assert_includes response.body, "Not a table note"
  end
end
