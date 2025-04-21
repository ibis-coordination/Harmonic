class ApiHelper
  attr_reader :current_user, :current_studio, :current_tenant,
              :current_representation_session, :current_resource_model,
              :current_resource, :model_params, :params, :request

  def initialize(
    current_user:, current_studio:, current_tenant:, current_representation_session:,
    current_resource_model:, current_resource: nil, model_params: nil, params: nil, request: nil
  )
    @current_user = current_user
    @current_studio = current_studio
    @current_tenant = current_tenant
    @current_representation_session = current_representation_session
    @current_resource_model = current_resource_model
    @model_params = model_params
    @current_resource = current_resource
    @request = request
  end

  def create
    case @current_resource_model
    when Note then create_note
    when Decision then create_decision
    when Commitment then create_commitment
    else
      raise "Create action for resource model #{@current_resource_model} is not implemented"
    end
  end

  def create_note
  end

  def create_decision
  end

  def create_commitment
  end

  def update_note
    note = current_note
    note.title = model_params[:title]
    note.text = model_params[:text]
    # Add files to note, but don't remove existing files
    if model_params[:files]
      model_params[:files].each do |file|
        note.files.attach(file)
      end
    end
    # note.deadline = Cycle.new_from_end_of_cycle_option(
    #   end_of_cycle: params[:end_of_cycle],
    #   tenant: current_tenant,
    #   studio: current_studio,
    # ).end_date
    if note.changed? || note.files_changed?
      note.updated_by = current_user
      ActiveRecord::Base.transaction do
        note.save!
        if current_representation_session
          current_representation_session.record_activity!(
            request: request,
            semantic_event: {
              timestamp: Time.current,
              event_type: 'update',
              studio_id: current_studio.id,
              main_resource: {
                type: 'Note',
                id: note.id,
                truncated_id: note.truncated_id,
              },
              sub_resources: [],
            }
          )
        end
      end
    end
    note
  end

  def confirm_read
    note = current_resource
    raise "Expected resource model Note, not #{note.class}" unless note.is_a?(Note)
    ActiveRecord::Base.transaction do
      history_event = note.confirm_read!(current_user)
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'confirm',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Note',
              id: note.id,
              truncated_id: note.truncated_id,
            },
            sub_resources: [{
              type: 'NoteHistoryEvent',
              id: history_event.id,
            }],
          }
        )
      end
      return history_event
    end
  end

  def current_note
    return nil unless @current_resource_model == Note && @current_resource.is_a?(Note)
    @current_resource
  end
end
