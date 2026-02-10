# typed: false

class NotesController < ApplicationController
  include AttachmentActions

  def show
    @note = current_note
    return render "404", status: :not_found unless @note

    @page_title = @note.title.presence || "Note #{@note.truncated_id}"
    @page_description = "Note page"
    @sidebar_mode = "resource"
    @team = @current_superagent.team
    set_pin_vars
    @note_reader = NoteReader.new(note: @note, user: current_user)
  end

  def new
    @page_title = "Note"
    @page_description = "Make a note for your team"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_superagent.tempo)
    @sidebar_mode = "resource"
    @team = @current_superagent.team
    @note = Note.new(
      title: params[:title]
    )
  end

  def edit
    @note = current_note
    @sidebar_mode = "resource"
    @team = @current_superagent.team
    return render "404", status: :not_found unless @note
    return render "shared/403", status: :forbidden unless @note.user_can_edit?(@current_user)

    @page_title = "Edit Note"
  end

  def create
    # Build params for ApiHelper (HTML form uses model_params)
    helper_params = { title: model_params[:title], text: model_params[:text] }
    @note = api_helper(params: helper_params).create_note
    # Handle file attachments separately (HTML form specific)
    if params[:files] && @current_tenant.allow_file_uploads? && @current_superagent.allow_file_uploads?
      @note.attach!(params[:files])
    end
    # Handle pinning (HTML form specific)
    if params[:pinned] == "1" && current_superagent.id != current_tenant.main_studio_id
      api_helper.pin_resource(@note)
    end
    redirect_to @note.path
  rescue ActiveRecord::RecordInvalid => e
    e.record.errors.full_messages.each { |msg| flash.now[:alert] = msg }
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_superagent.tempo)
    @note = Note.new(title: model_params[:title], text: model_params[:text])
    render :new
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

  public

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

  def update
    return render "404", status: :not_found unless current_note
    return render "shared/403", status: :forbidden unless current_note.user_can_edit?(@current_user)

    @note = api_helper.update_note
    redirect_to @note.path
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
    render_actions_index({
                           actions: [{
                             name: "confirm_read",
                             params_string: "()",
                           }],
                         })
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
    actions << if @note.is_pinned?(tenant: @current_tenant, superagent: @current_superagent, user: @current_user)
                 { name: "unpin_note", params_string: "()" }
               else
                 { name: "pin_note", params_string: "()" }
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
end
