# typed: false

class NotesController < ApplicationController
  include AttachmentActions
  include ParsesScheduledTime

  def show
    @note = current_note || find_deleted_note
    return render "404", status: :not_found unless @note

    @page_title = @note.title.presence || "Note #{@note.truncated_id}"
    @page_description = "Note page"
    @sidebar_mode = "resource"
    @team = @current_collective.team
    return if @note.deleted?

    set_pin_vars
    set_report_vars(@note)
    @note_reader = NoteReader.new(note: @note, user: current_user)
  end

  def new
    @page_title = "Note"
    @page_description = "Make a note for your team"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_collective.tempo)
    @sidebar_mode = "resource"
    @team = @current_collective.team
    @subtype = Note::SUBTYPES.include?(params[:subtype]) ? params[:subtype] : "text"
    @note = Note.new(
      title: params[:title]
    )
  end

  def report
    @note = current_note
    return render "404", status: :not_found unless @note
    return redirect_to("/login") unless @current_user

    @reportable = @note
    @reportable_type = "Note"
    @reportable_id = @note.id
    @page_title = "Report Content"
    @sidebar_mode = "resource"
    render "content_reports/new"
  end

  def edit
    @note = current_note
    return render "404", status: :not_found unless @note
    return redirect_to("#{@note.path}/settings") if @note.is_table?
    return render "shared/403", status: :forbidden unless @note.user_can_edit?(@current_user)

    @sidebar_mode = "resource"
    @team = @current_collective.team
    @page_title = "Edit Note"
  end

  def create
    if params[:subtype] == "table"
      create_table_note
    elsif params[:subtype] == "reminder"
      create_reminder_note
    else
      create_text_note
    end
  rescue ActiveRecord::RecordInvalid => e
    e.record.errors.full_messages.each { |msg| flash.now[:alert] = msg }
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_collective.tempo)
    @note = Note.new(title: model_params[:title], text: model_params[:text])
    render :new
  end

  def create_note
    note = api_helper.create_note
    render_action_success({
                            action_name: "create_note",
                            resource: note,
                            result: "Note created.",
                          })
  rescue ActiveRecord::RecordInvalid => e
    render_action_error({
                          action_name: "create_note",
                          resource: current_note,
                          error: e.message,
                        })
  end

  def describe_create_note
    render_action_description(ActionsHelper.action_description("create_note"))
  end

  def describe_create_reminder_note
    render_action_description(ActionsHelper.action_description("create_reminder_note"))
  end

  def create_reminder_note_action
    text = params[:text]
    title = params[:title]
    scheduled_for = parse_scheduled_time(params[:scheduled_for], timezone: params[:timezone])

    if text.blank?
      return render_action_error({ action_name: "create_reminder_note", error: "text is required" })
    end

    if scheduled_for.nil?
      return render_action_error({ action_name: "create_reminder_note", error: "scheduled_for is required and must be a valid time" })
    end

    helper_params = { text: text, title: title, subtype: "reminder" }
    note = api_helper(params: helper_params).create_note

    begin
      notification = ReminderService.create!(
        user: @current_user,
        title: note.title,
        scheduled_for: scheduled_for,
        url: note.path,
      )
      note.update!(reminder_notification_id: notification.id)
    rescue ReminderService::ReminderError => e
      note.destroy!
      return render_action_error({ action_name: "create_reminder_note", error: "Reminder scheduling failed: #{e.message}" })
    end

    render_action_success({
      action_name: "create_reminder_note",
      resource: note,
      result: "Reminder note created, scheduled for #{scheduled_for.strftime('%Y-%m-%d %H:%M %Z')}.",
    })
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    render_action_error({ action_name: "create_reminder_note", error: e.message })
  end

  def create_table_note_action
    note = api_helper.create_table_note
    render_action_success({
                            action_name: "create_table_note",
                            resource: note,
                            result: "Table note created.",
                          })
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    render_action_error({
                          action_name: "create_table_note",
                          error: e.message,
                        })
  end

  def describe_create_table_note
    render_action_description(ActionsHelper.action_description("create_table_note"))
  end

  def update
    return render "404", status: :not_found unless current_note
    return render "shared/403", status: :forbidden unless current_note.user_can_edit?(@current_user)

    @note = api_helper.update_note
    redirect_to @note.path
  end

  def update_settings
    @note = current_note
    return render "404", status: :not_found unless @note
    return render "shared/403", status: :forbidden unless @note.user_can_edit?(@current_user)

    # Build params that api_helper.update_note expects (it reads model_params)
    update_params = (model_params.respond_to?(:to_unsafe_h) ? model_params.to_unsafe_h : model_params.to_h).symbolize_keys
    update_params[:edit_access] = params[:edit_access] if params[:edit_access].present?
    @note = api_helper(params: update_params).update_note

    if @note.is_table? && params.key?(:table_description)
      table = NoteTableService.new(@note)
      table.update_description!(params[:table_description])
    end
    redirect_to @note.path, notice: "Settings saved."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to "#{@note.path}/settings", alert: e.message
  end

  def update_note
    note = api_helper.update_note
    render_action_success({
                            action_name: "update_note",
                            resource: note,
                            result: "Note updated.",
                          })
  rescue ActiveRecord::RecordInvalid => e
    render_action_error({
                          action_name: "update_note",
                          resource: current_note,
                          error: e.message,
                        })
  end

  def describe_update_note
    render_action_description(ActionsHelper.action_description("update_note", resource: current_note))
  end

  def confirm_and_return_partial
    # Must be logged in to confirm
    return render message: "You must be logged in to confirm.", status: :unauthorized unless current_user

    @note = current_note
    @note_reader = NoteReader.new(note: @note, user: current_user)
    api_helper.confirm_read
    render partial: "confirm"
  end

  def confirm_read
    api_helper.confirm_read
    respond_to do |format|
      format.json { render json: { success: true, confirmed_reads: current_note.confirmed_reads }, status: :ok }
      format.html { render_confirm_read_success }
      format.md { render_confirm_read_success }
    end
  rescue ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
      format.html { render_confirm_read_error(e.message) }
      format.md { render_confirm_read_error(e.message) }
    end
  end

  def describe_report_content
    render_action_description(ActionsHelper.action_description("report_content", resource: current_note))
  end

  def report_content_action
    return render "404", status: :not_found unless current_note

    api_helper.report_content(current_note)
    respond_to do |format|
      format.html { redirect_to current_note.path, notice: report_content_flash }
      format.md { render_action_success({ action_name: "report_content", resource: current_note, result: report_content_flash }) }
    end
  rescue ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.html { redirect_to current_note.path, alert: e.record.errors.full_messages.join(", ") }
      format.md { render_action_error({ action_name: "report_content", resource: current_note, error: e.message }) }
    end
  end

  def describe_confirm_read
    render_action_description(ActionsHelper.action_description("confirm_read", resource: current_note))
  end

  def history_log_partial
    @note = current_note
    return render "404", status: :not_found unless @note

    render partial: "history_log"
  end

  def actions_index_new
    @page_title = "Actions | Note"
    render_actions_index({
                           actions: [{
                             name: "create_note",
                             params_string: "(text)",
                           }],
                         })
  end

  def actions_index_edit
    @page_title = "Actions | Edit Note"
    render_actions_index({
                           actions: [{
                             name: "update_note",
                             params_string: "(text)",
                           }],
                         })
  end

  def actions_index_show
    @note = current_note
    @page_title = "Actions | #{@note.title}"
    route_info = ActionsHelper.actions_for_route("/collectives/:collective_handle/n/:note_id")
    actions = (route_info&.dig(:actions) || []).select do |action|
      ActionAuthorization.authorized?(action[:name], @current_user, { collective: @current_collective, resource: @note })
    end
    render_actions_index({ actions: actions })
  end

  def settings
    @note = current_note
    return render "404", status: :not_found unless @note
    return render "shared/403", status: :forbidden unless @note.user_can_edit?(@current_user)

    @page_title = "Note Settings"
    set_pin_vars
  end

  def actions_index_settings
    @note = current_note
    return render "404", status: :not_found unless @note

    @page_title = "Actions | Note Settings"
    actions = []
    actions << if @note.is_pinned?(tenant: @current_tenant, collective: @current_collective, user: @current_user)
                 { name: "unpin_note", params_string: "()" }
               else
                 { name: "pin_note", params_string: "()" }
               end
    if @current_user&.id == @note.created_by_id || @current_user&.collective_member&.is_admin? || @current_user&.app_admin?
      actions << { name: "delete_note", params_string: "()" }
    end
    render_actions_index({ actions: actions })
  end

  def describe_pin_note
    render_action_description(ActionsHelper.action_description("pin_note", resource: current_note))
  end

  def pin_note_action
    @note = current_note
    return render "404", status: :not_found unless @note

    begin
      api_helper.pin_resource(@note)
      render_action_success({
                              action_name: "pin_note",
                              resource: @note,
                              result: "Note pinned.",
                            })
    rescue StandardError => e
      render_action_error({
                            action_name: "pin_note",
                            resource: @note,
                            error: e.message,
                          })
    end
  end

  def describe_unpin_note
    render_action_description(ActionsHelper.action_description("unpin_note", resource: current_note))
  end

  def unpin_note_action
    @note = current_note
    return render "404", status: :not_found unless @note

    begin
      api_helper.unpin_resource(@note)
      render_action_success({
                              action_name: "unpin_note",
                              resource: @note,
                              result: "Note unpinned.",
                            })
    rescue StandardError => e
      render_action_error({
                            action_name: "unpin_note",
                            resource: @note,
                            error: e.message,
                          })
    end
  end

  def describe_delete_note
    render_action_description(ActionsHelper.action_description("delete_note", resource: current_note))
  end

  # Table note actions

  def describe_add_row
    render_action_description(ActionsHelper.action_description("add_row", resource: current_note))
  end

  def execute_add_row
    row = api_helper.add_row
    respond_to do |format|
      format.html { redirect_to current_note.path, notice: "Row added." }
      format.md { render_action_success({ action_name: "add_row", resource: current_note, result: "Row added (id: #{row['_id']})." }) }
    end
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.html { redirect_to current_note.path, alert: e.message }
      format.md { render_action_error({ action_name: "add_row", resource: current_note, error: e.message }) }
    end
  end

  def describe_update_row
    render_action_description(ActionsHelper.action_description("update_row", resource: current_note))
  end

  def execute_update_row
    api_helper.update_row
    render_action_success({ action_name: "update_row", resource: current_note, result: "Row updated." })
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    render_action_error({ action_name: "update_row", resource: current_note, error: e.message })
  end

  def describe_delete_row
    render_action_description(ActionsHelper.action_description("delete_row", resource: current_note))
  end

  def execute_delete_row
    api_helper.delete_row
    respond_to do |format|
      format.html { redirect_to current_note.path, notice: "Row deleted." }
      format.md { render_action_success({ action_name: "delete_row", resource: current_note, result: "Row deleted." }) }
    end
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.html { redirect_to current_note.path, alert: e.message }
      format.md { render_action_error({ action_name: "delete_row", resource: current_note, error: e.message }) }
    end
  end

  def describe_add_table_column
    render_action_description(ActionsHelper.action_description("add_table_column", resource: current_note))
  end

  def execute_add_table_column
    api_helper.add_table_column
    render_action_success({ action_name: "add_table_column", resource: current_note, result: "Column '#{params[:name]}' added." })
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    render_action_error({ action_name: "add_table_column", resource: current_note, error: e.message })
  end

  def describe_remove_table_column
    render_action_description(ActionsHelper.action_description("remove_table_column", resource: current_note))
  end

  def execute_remove_table_column
    api_helper.remove_table_column
    render_action_success({ action_name: "remove_table_column", resource: current_note, result: "Column '#{params[:name]}' removed." })
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    render_action_error({ action_name: "remove_table_column", resource: current_note, error: e.message })
  end

  def describe_query_rows
    render_action_description(ActionsHelper.action_description("query_rows", resource: current_note))
  end

  def execute_query_rows
    result = api_helper.query_rows
    table = api_helper.table_service
    markdown = NoteTableFormatter.to_markdown({
      "columns" => table.columns,
      "rows" => result[:rows],
    })
    render_action_success({
      action_name: "query_rows",
      resource: current_note,
      result: "#{result[:total]} rows match (showing #{result[:rows].length}):\n\n#{markdown}",
    })
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    render_action_error({ action_name: "query_rows", resource: current_note, error: e.message })
  end

  def describe_summarize
    render_action_description(ActionsHelper.action_description("summarize", resource: current_note))
  end

  def execute_summarize
    value = api_helper.summarize_table
    render_action_success({ action_name: "summarize", resource: current_note, result: "#{params[:operation]} = #{value}" })
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    render_action_error({ action_name: "summarize", resource: current_note, error: e.message })
  end

  def describe_update_table_description
    render_action_description(ActionsHelper.action_description("update_table_description", resource: current_note))
  end

  def execute_update_table_description
    api_helper.update_table_description
    render_action_success({ action_name: "update_table_description", resource: current_note, result: "Table description updated." })
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    render_action_error({ action_name: "update_table_description", resource: current_note, error: e.message })
  end

  def describe_batch_table_update
    render_action_description(ActionsHelper.action_description("batch_table_update", resource: current_note))
  end

  def execute_batch_table_update
    operations = params[:operations] || []
    api_helper.batch_table_update do |t|
      operations.each do |op|
        case op[:action]
        when "add_row"
          t.add_row!(op[:values]&.to_unsafe_h || {}, created_by: @current_user)
        when "update_row"
          t.update_row!(op[:row_id], op[:values]&.to_unsafe_h || {})
        when "delete_row"
          t.delete_row!(op[:row_id])
        when "add_table_column"
          raise "Unauthorized: only the table owner can add columns" unless current_note.user_can_edit?(@current_user)
          t.add_column!(op[:name], op[:type])
        when "remove_table_column"
          raise "Unauthorized: only the table owner can remove columns" unless current_note.user_can_edit?(@current_user)
          t.remove_column!(op[:name])
        when "update_table_description"
          raise "Unauthorized: only the table owner can update the description" unless current_note.user_can_edit?(@current_user)
          t.update_description!(op[:description])
        else
          raise "Unknown operation '#{op[:action]}'"
        end
      end
    end
    respond_to do |format|
      format.json { render json: { success: true, message: "#{operations.length} operations applied." } }
      format.html { redirect_to current_note.path, notice: "#{operations.length} operations applied." }
      format.md { render_action_success({ action_name: "batch_table_update", resource: current_note, result: "#{operations.length} operations applied." }) }
    end
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    respond_to do |format|
      format.json { render json: { success: false, error: e.message }, status: :unprocessable_entity }
      format.html { redirect_to current_note.path, alert: e.message }
      format.md { render_action_error({ action_name: "batch_table_update", resource: current_note, error: e.message }) }
    end
  end

  # Reminder note actions

  def describe_cancel_reminder
    render_action_description(ActionsHelper.action_description("cancel_reminder", resource: current_note))
  end

  def execute_cancel_reminder
    note = current_note
    return render_action_error({ action_name: "cancel_reminder", resource: note, error: "Not a reminder note" }) unless note&.is_reminder?
    return render_action_error({ action_name: "cancel_reminder", resource: note, error: "Not authorized" }) unless note.user_can_edit?(current_user)
    return render_action_error({ action_name: "cancel_reminder", resource: note, error: "No pending reminder" }) unless note.reminder_pending?

    note.cancel_reminder!

    respond_to do |format|
      format.html { redirect_to note.path, notice: "Reminder cancelled." }
      format.md { render_action_success({ action_name: "cancel_reminder", resource: note, result: "Reminder cancelled." }) }
    end
  rescue StandardError => e
    render_action_error({ action_name: "cancel_reminder", resource: current_note, error: e.message })
  end

  def execute_delete_note
    @note = current_note
    return render "404", status: :not_found unless @note

    begin
      api_helper.delete_note
      if @note.is_comment? && @note.commentable
        redirect_to @note.commentable.path, notice: "Comment deleted."
      else
        redirect_to(@current_collective.path || "/", notice: "Note deleted.")
      end
    rescue ActiveRecord::RecordInvalid
      render "shared/403", status: :forbidden
    end
  end

  private

  def render_confirm_read_success
    render_action_success({
                            action_name: "confirm_read",
                            resource: current_note,
                            params: [],
                            result: "You have successfully confirmed that you have read this note.",
                          })
  end

  def render_confirm_read_error(message)
    render_action_error({
                          action_name: "confirm_read",
                          resource: current_note,
                          error: message,
                        })
  end

  def create_text_note
    helper_params = { title: model_params[:title], text: model_params[:text] }
    @note = api_helper(params: helper_params).create_note
    if params[:files] && @current_tenant.allow_file_uploads? && @current_collective.allow_file_uploads?
      @note.attach!(params[:files])
    end
    if params[:pinned] == "1" && current_collective.id != current_tenant.main_collective_id
      api_helper.pin_resource(@note)
    end
    redirect_to @note.path
  end

  def create_table_note
    columns = (params[:columns] || {}).values.select { |c| c[:name].present? }.map do |c|
      { "name" => c[:name], "type" => c[:type] || "text" }
    end

    # Parse initial rows from CSV import (JSON array of hashes)
    initial_rows = []
    if params[:initial_rows].present?
      parsed = JSON.parse(params[:initial_rows]) rescue []
      col_names = columns.map { |c| c["name"] }
      initial_rows = parsed.map do |row|
        r = { "_id" => SecureRandom.hex(4), "_created_by" => @current_user.id, "_created_at" => Time.current.iso8601 }
        col_names.each { |name| r[name] = row[name]&.to_s }
        r
      end
    end

    helper_params = {
      title: params[:title].presence || "Table",
      text: "",
      subtype: "table",
      edit_access: params[:edit_access].presence || "owner",
      table_data: {
        "description" => params[:table_description].presence,
        "columns" => columns,
        "rows" => initial_rows,
      },
    }
    @note = api_helper(params: helper_params).create_note
    # Regenerate text from table data (includes initial rows)
    if initial_rows.any?
      @note.text = NoteTableFormatter.to_markdown(@note.table_data)
      @note.save!
    end
    redirect_to @note.path
  end

  def create_reminder_note
    scheduled_for = parse_scheduled_time(params[:scheduled_for], timezone: params[:timezone])

    if scheduled_for.nil?
      # Fall back to creating a regular text note if no valid time
      return create_text_note
    end

    helper_params = { title: model_params[:title], text: model_params[:text], subtype: "reminder" }
    @note = api_helper(params: helper_params).create_note

    begin
      notification = ReminderService.create!(
        user: @current_user,
        title: @note.title,
        scheduled_for: scheduled_for,
        url: @note.path,
      )
      @note.update!(reminder_notification_id: notification.id)
    rescue ReminderService::ReminderError => e
      @note.destroy!
      flash.now[:alert] = "Reminder scheduling failed: #{e.message}"
      @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_collective.tempo)
      @subtype = "reminder"
      @note = Note.new(title: model_params[:title], text: model_params[:text])
      return render :new
    end

    redirect_to @note.path
  end

  def find_deleted_note
    note_id = params[:id] || params[:note_id]
    return nil unless note_id

    if note_id.to_s.length == 8
      Note.with_deleted.find_by(truncated_id: note_id)
    else
      Note.with_deleted.find_by(id: note_id)
    end
  end
end
