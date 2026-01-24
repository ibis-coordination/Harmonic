# typed: false

class NotesController < ApplicationController
  include AttachmentActions

  layout 'pulse', only: [:show]

  def new
    @page_title = "Note"
    @page_description = "Make a note for your team"
    @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_superagent.tempo)
    @note = Note.new(
      title: params[:title],
    )
  end

  def create
    @note = Note.new(
      title: model_params[:title],
      text: model_params[:text],
      deadline: Time.now,
      # deadline: Cycle.new_from_end_of_cycle_option(
      #   end_of_cycle: params[:end_of_cycle],
      #   tenant: current_tenant,
      #   studio: current_superagent,
      # ).end_date,
      created_by: current_user,
    )
    begin
      ActiveRecord::Base.transaction do
        @note.save!
        if params[:files] && @current_tenant.allow_file_uploads? && @current_superagent.allow_file_uploads?
          @note.attach!(params[:files])
        end
        @current_note = @note
        if params[:pinned] == '1' && current_superagent.id != current_tenant.main_studio_id
          current_superagent.pin_item!(@note)
        end
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'create',
              superagent_id: current_superagent.id,
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
      @end_of_cycle_options = Cycle.end_of_cycle_options(tempo: current_superagent.tempo)
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
    render_action_description(ActionsHelper.action_description("create_note"))
  end

  def show
    @note = current_note
    return render '404', status: 404 unless @note
    @page_title = @note.title.present? ? @note.title : "Note #{@note.truncated_id}"
    @page_description = "Note page"
    @sidebar_mode = 'resource'
    @team = @current_superagent.team
    set_pin_vars
    @note_reader = NoteReader.new(note: @note, user: current_user)
  end

  def edit
    @note = current_note
    return render '404', status: 404 unless @note
    return render 'shared/403', status: 403 unless @note.user_can_edit?(@current_user)
    @page_title = "Edit Note"
    # Which cycle end date is this note deadline associated with?
  end

  def update
    return render '404', status: 404 unless current_note
    return render 'shared/403', status: 403 unless current_note.user_can_edit?(@current_user)
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
    render_action_description(ActionsHelper.action_description("update_note", resource: current_note))
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
            superagent_id: current_superagent.id,
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
    render_action_description(ActionsHelper.action_description("confirm_read", resource: current_note))
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
        params_string: '(text)',
      }]
    })
  end

  def actions_index_edit
    @page_title = "Actions | Edit Note"
    render_actions_index({
      actions: [{
        name: 'update_note',
        params_string: '(text)',
      }]
    })
  end

  def actions_index_show
    @note = current_note
    @page_title = "Actions | #{@note.title}"
    render_actions_index({
      actions: [{
        name: 'confirm_read',
        params_string: '()',
      }]
    })
  end

  def settings
    @note = current_note
    return render '404', status: 404 unless @note
    return render 'shared/403', status: 403 unless @note.user_can_edit?(@current_user)
    @page_title = "Note Settings"
    set_pin_vars
  end

  def actions_index_settings
    @note = current_note
    return render '404', status: 404 unless @note
    @page_title = "Actions | Note Settings"
    actions = []
    if @note.is_pinned?(tenant: @current_tenant, superagent: @current_superagent, user: @current_user)
      actions << { name: 'unpin_note', params_string: '()' }
    else
      actions << { name: 'pin_note', params_string: '()' }
    end
    render_actions_index({ actions: actions })
  end

  def describe_pin_note
    render_action_description(ActionsHelper.action_description("pin_note", resource: current_note))
  end

  def pin_note_action
    @note = current_note
    return render '404', status: 404 unless @note
    begin
      @note.pin!(tenant: @current_tenant, superagent: @current_superagent, user: @current_user)
      render_action_success({
        action_name: 'pin_note',
        resource: @note,
        result: "Note pinned.",
      })
    rescue => e
      render_action_error({
        action_name: 'pin_note',
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
    return render '404', status: 404 unless @note
    begin
      @note.unpin!(tenant: @current_tenant, superagent: @current_superagent, user: @current_user)
      render_action_success({
        action_name: 'unpin_note',
        resource: @note,
        result: "Note unpinned.",
      })
    rescue => e
      render_action_error({
        action_name: 'unpin_note',
        resource: @note,
        error: e.message,
      })
    end
  end

end