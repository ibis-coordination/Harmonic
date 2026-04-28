require "test_helper"

class ApiHelperTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    # Collective.scope_thread_to_collective sets the current collective and tenant.
    # In controller actions, this is handled by ApplicationController
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )
  end

  test "ApiHelper.create_collective creates a collective" do
    params = {
      name: "Collective Name",
      handle: "collective-handle",
      description: "This is a test collective.",
      timezone: "Pacific Time (US & Canada)",
      tempo: "daily",
      synchronization_mode: "improv"
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Collective,
      current_resource: nil,
      params: params,
      request: {}
    )
    collective = api_helper.create_collective
    assert collective.persisted?
    assert_equal params[:name], collective.name
    assert_equal params[:handle], collective.handle
    assert_equal params[:description], collective.description
    assert_equal params[:timezone], collective.timezone.name
    assert_equal params[:tempo], collective.tempo
    assert_equal params[:synchronization_mode], collective.synchronization_mode
    assert_equal @tenant, collective.tenant
    assert_equal @user, collective.created_by
  end

  test "ApiHelper.create_note creates a note" do
    params = {
      title: "Note Title",
      text: "This is a test note.",
      deadline: Time.current + 1.week
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Note,
      current_resource: nil,
      params: params,
      request: {}
    )
    note = api_helper.create_note
    assert note.persisted?
    assert_equal params[:title], note.title
    assert_equal params[:text], note.text
    assert_equal @user, note.created_by
  end

  test "ApiHelper.create_decision creates a decision" do
    params = {
      question: "What is the best approach?",
      description: "Discussing the best approach for the project.",
      deadline: Time.current + 1.week
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Decision,
      current_resource: nil,
      params: params,
      request: {}
    )
    decision = api_helper.create_decision
    assert decision.persisted?
    assert_equal params[:question], decision.question
    assert_equal params[:description], decision.description
    assert_equal @user, decision.created_by
  end

  test "ApiHelper.confirm_read raises error for invalid resource model" do
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Decision,
      current_resource: Decision.new,
      params: {},
      request: {}
    )
    assert_raises(RuntimeError, "Expected resource model Note, not Decision") do
      api_helper.confirm_read
    end
  end

  test "ApiHelper.confirm_read confirms read for a note" do
    note = create_note
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Note,
      current_resource: note,
      params: {},
      request: {}
    )
    history_event = api_helper.confirm_read
    assert history_event.persisted?
    assert_equal note, history_event.note
    assert_equal @user, history_event.user
  end

  test "ApiHelper.update_note updates note attributes" do
    note = create_note
    params = { title: "New Title", text: "Updated text." }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_representation_session: nil,
      current_resource_model: Note,
      current_resource: note,
      model_params: params,
      params: params,
      request: {}
    )
    updated_note = api_helper.update_note
    assert_equal "New Title", updated_note.title
    assert_equal "Updated text.", updated_note.text
    assert_equal @user, updated_note.updated_by
  end

  test "ApiHelper.create_decision_options creates decision options" do
    decision = create_decision
    params = { titles: ["Option Title"] }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    options = api_helper.create_decision_options
    assert_equal 1, options.count
    assert options.first.persisted?
    assert_equal "Option Title", options.first.title
    assert_equal decision, options.first.decision
  end

  test "ApiHelper.create_votes creates votes for multiple decision options" do
    decision = create_decision
    option1 = create_option(decision: decision, title: "Option A")
    option2 = create_option(decision: decision, title: "Option B")
    params = {
      votes: [
        { option_title: option1.title, accept: true, prefer: true },
        { option_title: option2.title, accept: true, prefer: false },
      ]
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    votes = api_helper.create_votes
    assert_equal 2, votes.count
    vote1 = votes.find { |v| v.option == option1 }
    vote2 = votes.find { |v| v.option == option2 }
    assert vote1.persisted?
    assert_equal 1, vote1.accepted
    assert_equal 1, vote1.preferred
    assert vote2.persisted?
    assert_equal 1, vote2.accepted
    assert_equal 0, vote2.preferred
  end

  test "ApiHelper.create_votes creates single vote when array has one element" do
    decision = create_decision
    option = create_option(decision: decision)
    params = {
      votes: [
        { option_title: option.title, accepted: false, preferred: false }
      ]
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    votes = api_helper.create_votes
    assert_equal 1, votes.count
    vote = votes.first
    assert vote.persisted?
    assert_equal 0, vote.accepted
    assert_equal 0, vote.preferred
    assert_equal option, vote.option
    assert_equal decision, vote.decision
    assert_equal @user, vote.decision_participant.user
  end

  test "ApiHelper.create_votes raises error for missing option" do
    decision = create_decision
    params = {
      votes: [
        { option_title: "Nonexistent Option", accept: true, prefer: false }
      ]
    }
    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_decision: decision,
      params: params,
      request: {}
    )
    assert_raises ArgumentError do
      api_helper.create_votes
    end
  end

  test "ApiHelper.start_user_representation_session creates a user representation session" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    grant.accept!

    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: {},
      request: {}
    )

    rep_session = api_helper.start_user_representation_session(grant: grant)

    assert rep_session.persisted?
    assert_nil rep_session.collective_id
    assert_equal @user, rep_session.representative_user
    # effective_user is the granting_user (the person being represented)
    assert_equal grant.granting_user, rep_session.effective_user
    assert_equal grant, rep_session.trustee_grant
    assert rep_session.confirmed_understanding
  end

  test "ApiHelper.start_user_representation_session raises error for inactive grant" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: other_user,
      trustee_user: @user,
      permissions: { "create_notes" => true },
    )
    # Grant is pending, not active

    api_helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: {},
      request: {}
    )

    assert_raises ArgumentError do
      api_helper.start_user_representation_session(grant: grant)
    end
  end

  test "ApiHelper.start_user_representation_session raises error for wrong user" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com", name: "Other User")
    @tenant.add_user!(other_user)

    grant = TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @user,
      trustee_user: other_user,  # other_user is trustee, not @user
      permissions: { "create_notes" => true },
    )
    grant.accept!

    api_helper = ApiHelper.new(
      current_user: @user,  # @user is NOT the trustee user
      current_collective: @collective,
      current_tenant: @tenant,
      params: {},
      request: {}
    )

    assert_raises ArgumentError do
      api_helper.start_user_representation_session(grant: grant)
    end
  end

  # === Table Note Operations ===

  def create_table_note_for_api
    Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      subtype: "table",
      title: "API Test Table",
      text: "",
      table_data: {
        "columns" => [
          { "name" => "Status", "type" => "text" },
          { "name" => "Amount", "type" => "number" },
        ],
        "rows" => [],
      },
    )
  end

  def table_api_helper(note, params: {})
    ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_resource_model: Note,
      current_resource: note,
      current_note: note,
      params: params,
    )
  end

  test "create_table_note creates a table note with columns" do
    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: {
        title: "Agent Table",
        columns: [
          { "name" => "Task", "type" => "text" },
          { "name" => "Done", "type" => "boolean" },
        ],
        description: "Agent task list",
        edit_access: "members",
      },
    )

    note = helper.create_table_note

    assert note.persisted?
    assert_equal "table", note.subtype
    assert_equal "Agent Table", note.title
    assert_equal "members", note.edit_access
    assert_equal 2, note.table_data["columns"].length
    assert_equal "Agent task list", note.table_data["description"]
  end

  test "create_table_note with initial_rows" do
    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: {
        title: "Prepopulated",
        columns: [{ "name" => "Task", "type" => "text" }],
        initial_rows: [
          { "Task" => "Do laundry" },
          { "Task" => "Buy groceries" },
        ],
      },
    )

    note = helper.create_table_note

    assert_equal 2, note.table_data["rows"].length
    assert_equal "Do laundry", note.table_data["rows"].first["Task"]
    assert_includes note.text, "Do laundry"
    assert_includes note.text, "Buy groceries"
  end

  test "create_table_note defaults edit_access to owner" do
    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: {
        title: "Locked Table",
        columns: [{ "name" => "Col", "type" => "text" }],
      },
    )

    note = helper.create_table_note
    assert_equal "owner", note.edit_access
  end

  test "add_row adds a row to table note" do
    note = create_table_note_for_api
    helper = table_api_helper(note, params: { values: { "Status" => "done", "Amount" => "42" } })

    row = helper.add_row

    assert row["_id"].present?
    assert_equal "done", row["Status"]
    assert_equal "42", row["Amount"]
    assert_equal 1, note.reload.table_data["rows"].length
  end

  test "update_row updates specific cells" do
    note = create_table_note_for_api
    table = NoteTableService.new(note)
    row = table.add_row!({ "Status" => "pending", "Amount" => "10" }, created_by: @user)

    helper = table_api_helper(note, params: { row_id: row["_id"], values: { "Status" => "done" } })
    updated = helper.update_row

    assert_equal "done", updated["Status"]
    assert_equal "10", updated["Amount"]
  end

  test "delete_row removes a row" do
    note = create_table_note_for_api
    table = NoteTableService.new(note)
    row = table.add_row!({ "Status" => "done", "Amount" => "10" }, created_by: @user)

    helper = table_api_helper(note, params: { row_id: row["_id"] })
    helper.delete_row

    assert_equal 0, note.reload.table_data["rows"].length
  end

  test "query_rows filters and paginates" do
    note = create_table_note_for_api
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Amount" => "10" }, created_by: @user)
    table.add_row!({ "Status" => "pending", "Amount" => "20" }, created_by: @user)
    table.add_row!({ "Status" => "done", "Amount" => "30" }, created_by: @user)

    helper = table_api_helper(note, params: { where: { "Status" => "done" }, limit: 10 })
    result = helper.query_rows

    assert_equal 2, result[:total]
    assert_equal 2, result[:rows].length
  end

  test "summarize_table computes aggregation" do
    note = create_table_note_for_api
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Amount" => "10" }, created_by: @user)
    table.add_row!({ "Status" => "done", "Amount" => "20" }, created_by: @user)

    helper = table_api_helper(note, params: { operation: "sum", column: "Amount" })
    assert_equal 30.0, helper.summarize_table
  end

  test "batch_table_update applies multiple operations" do
    note = create_table_note_for_api
    helper = table_api_helper(note)

    helper.batch_table_update do |t|
      t.add_row!({ "Status" => "a", "Amount" => "1" }, created_by: @user)
      t.add_row!({ "Status" => "b", "Amount" => "2" }, created_by: @user)
    end

    assert_equal 2, note.reload.table_data["rows"].length
    assert_equal 1, note.note_history_events.where(event_type: "update").count
  end

  test "add_table_column adds a column" do
    note = create_table_note_for_api
    helper = table_api_helper(note, params: { name: "Priority", type: "text" })
    helper.add_table_column

    table = NoteTableService.new(note.reload)
    assert_equal 3, table.columns.length
    assert_includes table.column_names, "Priority"
  end

  test "remove_table_column removes a column" do
    note = create_table_note_for_api
    table = NoteTableService.new(note)
    table.add_row!({ "Status" => "done", "Amount" => "10" }, created_by: @user)

    helper = table_api_helper(note, params: { name: "Amount" })
    helper.remove_table_column

    table_after = NoteTableService.new(note.reload)
    assert_equal 1, table_after.columns.length
    refute_includes table_after.column_names, "Amount"
  end

  test "update_table_description updates description" do
    note = create_table_note_for_api
    helper = table_api_helper(note, params: { description: "Updated description" })
    helper.update_table_description

    table = NoteTableService.new(note.reload)
    assert_equal "Updated description", table.description
  end

  test "add_row is blocked when edit_access is owner and user is not owner" do
    note = create_table_note_for_api
    note.update!(edit_access: "owner")

    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    @collective.add_user!(other_user)

    helper = ApiHelper.new(
      current_user: other_user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_resource_model: Note,
      current_resource: note,
      current_note: note,
      params: { values: { "Status" => "done" } },
    )

    assert_raises(RuntimeError, "Unauthorized") do
      helper.add_row
    end
  end

  test "add_row is allowed when edit_access is members" do
    note = create_table_note_for_api
    note.update!(edit_access: "members") # default is "owner", override for this test

    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    @collective.add_user!(other_user)

    helper = ApiHelper.new(
      current_user: other_user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_resource_model: Note,
      current_resource: note,
      current_note: note,
      params: { values: { "Status" => "done" } },
    )

    row = helper.add_row
    assert row["_id"].present?
  end

  test "add_table_column requires resource owner" do
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    @collective.add_user!(other_user)
    note = create_table_note_for_api

    helper = ApiHelper.new(
      current_user: other_user,
      current_collective: @collective,
      current_tenant: @tenant,
      current_resource_model: Note,
      current_resource: note,
      current_note: note,
      params: { name: "New Col", type: "text" },
    )

    assert_raises(RuntimeError, "Unauthorized") do
      helper.add_table_column
    end
  end

  # === create_reminder_note tests ===

  test "create_reminder_note creates a reminder note with scheduled notification" do
    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: { text: "Don't forget the standup", title: "Standup Reminder" },
    )

    note = helper.create_reminder_note(scheduled_for: 1.day.from_now.in_time_zone("UTC"))

    assert note.persisted?
    assert_equal "reminder", note.subtype
    assert_equal "Don't forget the standup", note.text
    assert_not_nil note.reminder_notification_id
    assert_not_nil note.reminder_scheduled_for
    assert note.reminder_pending?
  end

  test "create_reminder_note includes mentioned collective members as recipients" do
    mentioned_user = create_user(name: "Mentioned")
    @tenant.add_user!(mentioned_user)
    @collective.add_user!(mentioned_user)
    mentioned_user.tenant_user.update!(handle: "mentioned")

    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: { text: "Hey @mentioned check on the deploy", title: nil },
    )

    note = helper.create_reminder_note(scheduled_for: 1.day.from_now.in_time_zone("UTC"))

    recipient_user_ids = note.reminder_notification.notification_recipients.map(&:user_id)
    assert_includes recipient_user_ids, @user.id
    assert_includes recipient_user_ids, mentioned_user.id
  end

  test "create_reminder_note excludes mentioned non-members" do
    non_member = create_user(name: "Outsider")
    @tenant.add_user!(non_member)
    non_member.tenant_user.update!(handle: "outsider")
    # NOT added to @collective

    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: { text: "Hey @outsider secret info", title: nil },
    )

    note = helper.create_reminder_note(scheduled_for: 1.day.from_now.in_time_zone("UTC"))

    recipient_user_ids = note.reminder_notification.notification_recipients.map(&:user_id)
    assert_includes recipient_user_ids, @user.id
    refute_includes recipient_user_ids, non_member.id
  end

  test "create_reminder_note destroys note on scheduling failure" do
    helper = ApiHelper.new(
      current_user: @user,
      current_collective: @collective,
      current_tenant: @tenant,
      params: { text: "Past time", title: nil },
    )

    assert_no_difference "Note.count" do
      assert_raises(ReminderService::ReminderSchedulingError) do
        helper.create_reminder_note(scheduled_for: 1.day.ago.in_time_zone("UTC"))
      end
    end
  end
end