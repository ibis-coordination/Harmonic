class NotesController < ApplicationController

  def new
    @page_title = "Note"
    @page_description = "Make a note for your team"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_studio.tempo)
    @scratchpad_links = current_user.scratchpad_links(tenant: current_tenant, studio: current_studio)
    @note = Note.new(
      title: params[:title],
    )
  end

  def create
    @note = Note.new(
      title: model_params[:title],
      text: model_params[:text],
      deadline: Cycle.new_from_end_of_cycle_option(
        end_of_cycle: params[:end_of_cycle],
        tenant: current_tenant,
        studio: current_studio,
      ).end_date,
      created_by: current_user,
    )
    begin
      ActiveRecord::Base.transaction do
        @note.save!
        if params[:files] && @current_tenant.allow_file_uploads? && @current_studio.allow_file_uploads?
          @note.attach!(params[:files])
        end
        @current_note = @note
        if params[:pinned] == '1' && current_studio.id != current_tenant.main_studio_id
          current_studio.pin_item!(@note)
        end
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'create',
              studio_id: current_studio.id,
              main_resource: {
                type: 'Note',
                id: @note.id,
                truncated_id: @note.truncated_id,
              },
              sub_resources: [],
            }
          )
        end
      end
      redirect_to @note.path
    rescue ActiveRecord::RecordInvalid => e
      e.record.errors.full_messages.each do |msg|
        flash.now[:alert] = msg
      end
      @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_studio.tempo)
      @scratchpad_links = current_user.scratchpad_links(tenant: current_tenant, studio: current_studio)
      @note = Note.new(
        title: model_params[:title],
        text: model_params[:text],
      )
      render :new
    end
  end

  def create_note
    begin
      note = api_helper.create_note
      render_action_success({
        action_name: 'create_note',
        resource: note,
        result: "Note created.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'create_note',
        resource: current_note,
        error: e.message,
      })
    end
  end

  def describe_create_note
    render_action_description({
      action_name: 'create_note',
      description: "Create a new note",
      params: [
        {
          name: 'title',
          description: 'The title of the note',
          type: 'string',
        },
        {
          name: 'text',
          description: 'The text of the note',
          type: 'string',
        },
        {
          name: 'deadline',
          description: 'The deadline of the note',
          type: 'datetime',
        }
      ]
    })
  end

  def show
    @note = current_note
    return render '404', status: 404 unless @note
    @page_title = @note.title
    @page_description = "Note page"
    set_pin_vars
    @note_reader = NoteReader.new(note: @note, user: current_user)
  end

  def edit
    @note = current_note
    @scratchpad_links = current_user.scratchpad_links(tenant: current_tenant, studio: current_studio)
    return render '404', status: 404 unless @note
    @page_title = "Edit Note"
    # Which cycle end date is this note deadline associated with?
  end

  def update
    return render '404', status: 404 unless current_note
    @note = api_helper.update_note
    redirect_to @note.path
  end

  def update_note
    begin
      note = api_helper.update_note
      render_action_success({
        action_name: 'update_note',
        resource: note,
        result: "Note updated.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'update_note',
        resource: current_note,
        error: e.message,
      })
    end
  end

  def describe_update_note
    render_action_description({
      action_name: 'update_note',
      resource: current_note,
      description: "Update this note.",
      params: [
        {
          name: 'title',
          description: 'The updated title of the note',
          type: 'string',
        },
        {
          name: 'text',
          description: 'The updated text of the note',
          type: 'string',
        },
        {
          name: 'deadline',
          description: 'The updated deadline of the note',
          type: 'datetime',
        }
      ]
    })
  end

  def confirm_and_return_partial
    # Must be logged in to confirm
    unless current_user
      return render message: 'You must be logged in to confirm.', status: 401
    end
    @note = current_note
    @note_reader = NoteReader.new(note: @note, user: current_user)
    ActiveRecord::Base.transaction do
      confirmation = @note.confirm_read!(current_user)
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'confirm',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Note',
              id: @note.id,
              truncated_id: @note.truncated_id,
            },
            sub_resources: [{
              type: 'NoteHistoryEvent',
              id: confirmation.id,
            }],
          }
        )
      end
    end
    render partial: 'confirm'
  end

  def confirm_read
    begin
      api_helper.confirm_read
      render_action_success({
        action_name: 'confirm_read',
        resource: current_note,
        params: [],
        result: "You have successfully confirmed that you have read this note.",
      })
    rescue ActiveRecord::RecordInvalid => e
      render_action_error({
        action_name: 'confirm_read',
        resource: current_note,
        error: e.message,
      })
    end
  end

  def describe_confirm_read
    render_action_description({
      action_name: 'confirm_read',
      resource: current_note,
      description: "Confirm that you have read this note.",
      params: []
    })
  end

  def history_log_partial
    @note = current_note
    return render '404', status: 404 unless @note
    render partial: 'history_log'
  end

  def actions_index_new
    @page_title = "Actions | Note"
    render_actions_index({
      actions: [{
        name: 'create_note',
        params_string: '(title, text, deadline)',
      }]
    })
  end

  def actions_index_edit
    @page_title = "Actions | Edit Note"
    render_actions_index({
      actions: [{
        name: 'update_note',
        params_string: '(title, text, deadline)',
      }]
    })
  end

  def actions_index_show
    @page_title = "Actions | #{@note.title}"
    render_actions_index({
      actions: [{
        name: 'confirm_read',
        params_string: '()',
      }]
    })
  end

end