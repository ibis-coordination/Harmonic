class ApiHelper
  attr_reader :current_user, :current_studio, :current_tenant,
              :current_representation_session, :current_resource_model,
              :current_resource, :current_note, :current_decision,
              :current_commitment, :current_decision_participant,
              :current_commitment_participant,
              :model_params, :params, :request

  def initialize(
    current_user:, current_studio:, current_tenant:,
    current_resource_model: nil,  current_resource: nil, current_note: nil,
    current_decision: nil, current_commitment: nil,
    current_decision_participant: nil, current_commitment_participant: nil,
    model_params: nil, params: nil, request: nil,
    current_representation_session: nil
  )
    @current_user = current_user
    @current_studio = current_studio
    @current_tenant = current_tenant
    @current_representation_session = current_representation_session
    @current_resource_model = current_resource_model
    @current_resource = current_resource
    @current_note = current_note
    @current_decision = current_decision
    @current_commitment = current_commitment
    @current_decision_participant = current_decision_participant
    @current_commitment_participant = current_commitment_participant
    @model_params = model_params || params
    @params = params || model_params
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

  def create_studio
    studio = nil
    note = nil
    ActiveRecord::Base.transaction do
      studio = Studio.create!(
        name: params[:name],
        handle: params[:handle],
        description: params[:description],
        created_by: current_user,
        timezone: params[:timezone],
        tempo: params[:tempo],
        synchronization_mode: params[:synchronization_mode],
      )
      # This is needed to ensure that all the models created in this transaction
      # are associated with the correct tenant and studio
      Studio.scope_thread_to_studio(handle: studio.handle, subdomain: studio.tenant.subdomain)
      studio.add_user!(current_user, roles: ['admin', 'representative'])
      decision = studio.create_welcome_decision!
      commitment = studio.create_welcome_commitment!
      note = studio.create_welcome_note!(decision: decision, commitment: commitment)
    end
    studio
  end

  def create_note
    note = nil
    ActiveRecord::Base.transaction do
      note = Note.create!(
        title: params[:title],
        text: params[:text],
        deadline: params[:deadline],
        created_by: current_user,
      )
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'create',
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
    note
  end

  def create_decision
    decision = nil
    ActiveRecord::Base.transaction do
      decision = Decision.create!(
        question: params[:question],
        description: params[:description],
        options_open: params[:options_open] || true,
        deadline: params[:deadline],
        created_by: current_user,
      )
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'create',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Decision',
              id: decision.id,
              truncated_id: decision.truncated_id,
            },
            sub_resources: [],
          }
        )
      end
    end
    decision
  end

  def create_commitment
    raise NotImplementedError
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
    history_event = nil
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
    end
    history_event
  end

  def create_decision_option
    option = nil
    ActiveRecord::Base.transaction do
      current_decision_participant = DecisionParticipantManager.new(
        decision: current_decision,
        user: current_user,
      ).find_or_create_participant
      unless current_decision.can_add_options?(current_decision_participant)
        raise "Cannot add options to decision #{decision.id} for user #{current_user.id}"
      end
      option = Option.create!(
        decision: current_decision,
        decision_participant: current_decision_participant,
        title: params[:title],
        description: params[:description],
      )
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'add_option',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Decision',
              id: current_decision.id,
              truncated_id: current_decision.truncated_id,
            },
            sub_resources: [
              {
                type: 'Option',
                id: option.id,
              },
            ],
          }
        )
      end
    end
    option
  end

  def vote
    associations = {
      tenant: current_tenant,
      studio: current_studio,
      decision: current_decision,
      option: current_option,
      decision_participant: current_decision_participant,
    }
    # If the approval already exists, update it. Otherwise, create a new one.
    # There should only be one approval record per decision + option + participant.
    approval = Approval.find_by(associations) || Approval.new(associations)
    approval.value = params[:value] || params[:accept]
    approval.stars = params[:stars] || params[:prefer]
    ActiveRecord::Base.transaction do
      approval.save!
      if current_representation_session
        current_representation_session.record_activity!(
          request: request,
          semantic_event: {
            timestamp: Time.current,
            event_type: 'vote',
            studio_id: current_studio.id,
            main_resource: {
              type: 'Decision',
              id: current_decision.id,
              truncated_id: current_decision.truncated_id,
            },
            sub_resources: [
              {
                type: 'Option',
                id: current_option.id,
              },
              {
                type: 'Approval',
                id: approval.id,
              },
            ],
          }
        )
      end
    end
    approval
  end

  def create_simulated_user
    # Only simulated users can be created via the API
    user = nil
    ActiveRecord::Base.transaction do
      user = User.create!(
        name: params[:name],
        email: SecureRandom.uuid + '@not-a-real-email.com',
        user_type: 'simulated',
        parent_id: current_user.id,
      )
      tenant_user = current_tenant.add_user!(user)
      user.tenant_user = tenant_user
    end
    user
  end

  def generate_token(user)
    ApiToken.create!(
      name: "#{user.display_name}'s API Token",
      user: user,
      expires_at: 1.year.from_now,
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
    )
  end

  def current_note
    return @current_note if @current_note
    return nil unless @current_resource_model == Note && @current_resource.is_a?(Note)
    @current_resource
  end

  def current_decision
    return @current_decision if @current_decision
    return nil unless @current_resource_model == Decision && @current_resource.is_a?(Decision)
    @current_resource
  end

  def current_commitment
    return @current_commitment if @current_commitment
    return nil unless @current_resource_model == Commitment && @current_resource.is_a?(Commitment)
    @current_resource
  end

  def current_decision_participant
    return @current_decision_participant if @current_decision_participant
    if @current_resource_model == DecisionParticipant && @current_resource.is_a?(DecisionParticipant)
      @current_resource
    else
      @current_decision_participant = DecisionParticipantManager.new(
        decision: current_decision,
        user: current_user,
      ).find_or_create_participant
    end
    @current_decision_participant
  end

  def current_commitment_participant
    return @current_commitment_participant if @current_commitment_participant
    return nil unless @current_resource_model == CommitmentParticipant && @current_resource.is_a?(CommitmentParticipant)
    @current_resource
  end

  def current_option
    return @current_option if @current_option
    if params[:option_id]
      @current_option = current_decision.options.find_by(id: params[:option_id])
    elsif params[:option_title]
      # Option title is unique per decision, so we can use it to find the option.
      @current_option = current_decision.options.find_by(title: params[:option_title])
    elsif @current_resource_model == Option && @current_resource.is_a?(Option)
      @current_option = @current_resource
    end
    @current_option
  end

end
