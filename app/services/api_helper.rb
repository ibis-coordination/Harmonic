# typed: true

class ApiHelper
  extend T::Sig

  attr_reader :current_user, :current_superagent, :current_tenant,
              :current_representation_session, :current_resource_model,
              :current_resource, :current_note, :current_decision,
              :current_commitment, :current_decision_participant,
              :current_commitment_participant,
              :model_params, :params, :request

  sig do
    params(
      current_user: User,
      current_superagent: Superagent,
      current_tenant: Tenant,
      current_resource_model: T.nilable(T::Class[T.anything]),
      current_resource: T.untyped,
      current_note: T.nilable(Note),
      current_decision: T.nilable(Decision),
      current_commitment: T.nilable(Commitment),
      current_decision_participant: T.nilable(DecisionParticipant),
      current_commitment_participant: T.nilable(CommitmentParticipant),
      model_params: T.untyped,
      params: T.untyped,
      request: T.untyped,
      current_representation_session: T.nilable(RepresentationSession),
      current_cycle: T.nilable(Cycle),
      current_heartbeat: T.nilable(Heartbeat)
    ).void
  end
  def initialize(
    current_user:, current_superagent:, current_tenant:,
    current_resource_model: nil,  current_resource: nil, current_note: nil,
    current_decision: nil, current_commitment: nil,
    current_decision_participant: nil, current_commitment_participant: nil,
    model_params: nil, params: nil, request: nil,
    current_representation_session: nil, current_cycle: nil, current_heartbeat: nil
  )
    @current_user = current_user
    @current_superagent = current_superagent
    @current_tenant = current_tenant
    @current_representation_session = current_representation_session
    @current_cycle = current_cycle
    @current_heartbeat = current_heartbeat
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

  # Check if the current user has the capability to perform an action.
  sig { returns(T.any(Note, Decision, Commitment)) }
  def create
    case @current_resource_model
    when Note then create_note
    when Decision then create_decision
    when Commitment then create_commitment
    else
      raise "Create action for resource model #{@current_resource_model} is not implemented"
    end
  end

  sig { returns(Superagent) }
  def create_studio
    studio = T.let(nil, T.nilable(Superagent))
    note = nil
    ActiveRecord::Base.transaction do
      studio = Superagent.create!(
        name: params[:name],
        handle: params[:handle],
        description: params[:description],
        created_by: current_user,
        timezone: params[:timezone],
        tempo: params[:tempo],
        synchronization_mode: params[:synchronization_mode],
      )

      # Apply optional settings
      if params.has_key?(:invitations)
        studio.settings['all_members_can_invite'] = params[:invitations] == 'all_members'
      end
      if params.has_key?(:representation)
        studio.settings['any_member_can_represent'] = params[:representation] == 'any_member'
      end
      if params.has_key?(:file_uploads)
        studio.settings['allow_file_uploads'] = params[:file_uploads] == true || params[:file_uploads] == 'true' || params[:file_uploads] == '1'
      end
      if params.has_key?(:api_enabled)
        studio.settings['feature_flags'] ||= {}
        studio.settings['feature_flags']['api'] = params[:api_enabled] == true || params[:api_enabled] == 'true' || params[:api_enabled] == '1'
      end
      studio.save! if studio.settings_changed?

      # This is needed to ensure that all the models created in this transaction
      # are associated with the correct tenant and studio
      Superagent.scope_thread_to_superagent(handle: studio.handle, subdomain: T.must(studio.tenant).subdomain)
      studio.add_user!(current_user, roles: ['admin', 'representative'])
    end
    T.must(studio)
  end

  sig { returns(Superagent) }
  def create_scene
    scene = T.let(nil, T.nilable(Superagent))
    note = nil
    ActiveRecord::Base.transaction do
      scene = Superagent.create!(
        superagent_type: 'scene',
        name: params[:name],
        handle: params[:handle],
        description: params[:description],
        created_by: current_user,
        open_scene: (params[:open_scene].to_s == 'true') || (params[:invitation_mode] == 'open'),
        # timezone: params[:timezone],
        # tempo: params[:tempo],
        # synchronization_mode: params[:synchronization_mode],
      )
      # This is needed to ensure that all the models created in this transaction
      # are associated with the correct tenant and scene
      Superagent.scope_thread_to_superagent(handle: scene.handle, subdomain: T.must(scene.tenant).subdomain)
      scene.add_user!(current_user, roles: ['admin', 'representative'])
    end
    T.must(scene)
  end

  sig { returns(Heartbeat) }
  def create_heartbeat
    heartbeat = T.let(nil, T.nilable(Heartbeat))
    ActiveRecord::Base.transaction do
      association_params = {
        tenant: current_tenant,
        superagent: current_superagent,
        user: current_user
      }
      existing_heartbeat = Heartbeat.where(
        association_params
      ).where(
        'created_at > ? and expires_at > ?', T.must(@current_cycle).start_date, Time.current
      ).first
      raise 'Heartbeat already exists' if existing_heartbeat
      heartbeat = Heartbeat.create!(
        association_params.merge(expires_at: T.must(@current_cycle).end_date)
      )
      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: "send_heartbeat",
          resource: heartbeat
        )
      end
    end
    T.must(heartbeat)
  end

  sig { params(commentable: T.nilable(T.any(Note, Decision, Commitment, RepresentationSession))).returns(Note) }
  def create_note(commentable: nil)
    note = T.let(nil, T.nilable(Note))
    ActiveRecord::Base.transaction do
      note = Note.create!(
        title: params[:title],
        text: params[:text],
        deadline: Time.now,
        created_by: current_user,
        commentable: commentable,
      )
      track_task_run_resource(note, action_type: "create")
      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: commentable.present? ? "add_comment" : "create_note",
          resource: note,
          context_resource: commentable
        )
      end
    end
    T.must(note)
  end

  sig { returns(Decision) }
  def create_decision
    decision = T.let(nil, T.nilable(Decision))
    ActiveRecord::Base.transaction do
      decision = Decision.create!(
        question: params[:question],
        description: params[:description],
        options_open: params[:options_open] || true,
        deadline: params[:deadline],
        created_by: current_user,
      )
      track_task_run_resource(decision, action_type: "create")
      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: "create_decision",
          resource: decision
        )
      end
    end
    T.must(decision)
  end

  sig { returns(Commitment) }
  def create_commitment
    commitment = T.let(nil, T.nilable(Commitment))
    ActiveRecord::Base.transaction do
      commitment = Commitment.create!(
        title: params[:title],
        description: params[:description],
        deadline: params[:deadline],
        critical_mass: params[:critical_mass],
        created_by: current_user,
      )
      # Handle close_at_critical_mass option
      if params[:close_at_critical_mass] == true || params[:close_at_critical_mass] == "true"
        commitment.limit = commitment.critical_mass
        commitment.save!
      end
      track_task_run_resource(commitment, action_type: "create")
      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: "create_commitment",
          resource: commitment
        )
      end
    end
    T.must(commitment)
  end

  sig { returns(CommitmentParticipant) }
  def join_commitment
    commitment = T.must(current_commitment)
    raise "Commitment is closed" if commitment.closed?

    participant = T.let(nil, T.nilable(CommitmentParticipant))
    ActiveRecord::Base.transaction do
      participant = CommitmentParticipantManager.new(
        commitment: commitment,
        user: current_user
      ).find_or_create_participant
      participant.committed = true
      participant.save!
      commitment.close_if_limit_reached!
      track_task_run_resource(participant, action_type: "join")
      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: "join_commitment",
          resource: participant,
          context_resource: commitment
        )
      end
    end
    T.must(participant)
  end

  sig { returns(Note) }
  def update_note
    note = T.must(current_note)
    raise 'Unauthorized' unless note.user_can_edit?(current_user)
    note.title = model_params[:title] if model_params[:title].present?
    note.text = model_params[:text] if model_params[:text].present?
    note.deadline = model_params[:deadline] if model_params[:deadline].present?
    # Add files to note, but don't remove existing files
    if model_params[:files]
      model_params[:files].each do |file|
        T.unsafe(note).files.attach(file)
      end
    end
    # note.deadline = Cycle.new_from_end_of_cycle_option(
    #   end_of_cycle: params[:end_of_cycle],
    #   tenant: current_tenant,
    #   superagent: current_superagent,
    # ).end_date
    if note.changed? || T.unsafe(note).files_changed?
      note.updated_by = current_user
      ActiveRecord::Base.transaction do
        note.save!
        if current_representation_session
          current_representation_session.record_event!(
            request: request,
            action_name: "update_note",
            resource: note
          )
        end
      end
    end
    note
  end

  sig { returns(NoteHistoryEvent) }
  def confirm_read
    note = current_resource
    raise "Expected resource model Note, not #{note.class}" unless note.is_a?(Note)
    history_event = T.let(nil, T.nilable(NoteHistoryEvent))
    ActiveRecord::Base.transaction do
      history_event = note.confirm_read!(current_user)
      track_task_run_resource(history_event, action_type: "confirm")
      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: "confirm_read",
          resource: history_event,
          context_resource: note
        )
      end
    end
    T.must(history_event)
  end

  # Backwards-compatible method for REST API v1 (creates single option from params[:title])
  sig { returns(Option) }
  def create_decision_option
    title = params[:title]
    raise ArgumentError, "title parameter is required" if title.blank?

    # Wrap params to use the bulk method
    original_params = params
    @params = params.merge(titles: [title])
    options = create_decision_options
    @params = original_params
    T.must(options.first)
  end

  sig { returns(T::Array[Option]) }
  def create_decision_options
    titles = params[:titles]
    raise ArgumentError, "titles parameter is required" if titles.blank?
    raise ArgumentError, "titles must be an array" unless titles.is_a?(Array)

    options = T.let([], T::Array[Option])
    ActiveRecord::Base.transaction do
      current_decision_participant = DecisionParticipantManager.new(
        decision: T.must(current_decision),
        user: current_user,
      ).find_or_create_participant
      unless T.must(current_decision).can_add_options?(current_decision_participant)
        raise "Cannot add options to decision #{T.must(current_decision).id} for user #{current_user.id}"
      end

      titles.each do |title|
        option = Option.create!(
          decision: current_decision,
          decision_participant: current_decision_participant,
          title: title,
        )
        track_task_run_resource(option, action_type: "add_options")
        options << option
      end

      if current_representation_session
        current_representation_session.record_events!(
          request: request,
          action_name: "add_options",
          resources: options,
          context_resource: current_decision
        )
      end
    end
    options
  end

  # Backwards-compatible method for REST API v1 (creates single vote for current_option)
  sig { returns(Vote) }
  def vote
    raise ArgumentError, "current_option is required" if current_option.blank?

    associations = {
      tenant: current_tenant,
      superagent: current_superagent,
      decision: current_decision,
      option: current_option,
      decision_participant: current_decision_participant,
    }
    # If the vote already exists, update it. Otherwise, create a new one.
    vote = Vote.find_by(associations) || Vote.new(associations)
    vote.accepted = params[:accepted] if params[:accepted].present?
    vote.preferred = params[:preferred] if params[:preferred].present?
    vote.save!
    track_task_run_resource(vote, action_type: "vote")

    if current_representation_session
      current_representation_session.record_event!(
        request: request,
        action_name: "vote",
        resource: vote,
        context_resource: current_decision
      )
    end
    vote
  end

  sig { returns(T::Array[Vote]) }
  def create_votes
    votes_param = params[:votes]
    raise ArgumentError, "votes parameter is required" if votes_param.blank?
    raise ArgumentError, "votes must be an array" unless votes_param.is_a?(Array)

    votes = T.let([], T::Array[Vote])
    ActiveRecord::Base.transaction do
      votes_param.each do |vote_data|
        option_title = vote_data[:option_title] || vote_data["option_title"]
        raise ArgumentError, "option_title is required for each vote" if option_title.blank?

        option = T.must(current_decision).options.find_by(title: option_title)
        raise ArgumentError, "Option '#{option_title}' not found" if option.nil?

        associations = {
          tenant: current_tenant,
          superagent: current_superagent,
          decision: current_decision,
          option: option,
          decision_participant: current_decision_participant,
        }
        # If the vote already exists, update it. Otherwise, create a new one.
        # There should only be one vote record per decision + option + participant.
        vote = Vote.find_by(associations) || Vote.new(associations)
        accept_value = vote_data[:accept] || vote_data["accept"] || vote_data[:accepted] || vote_data["accepted"]
        prefer_value = vote_data[:prefer] || vote_data["prefer"] || vote_data[:preferred] || vote_data["preferred"]
        # Convert boolean to integer (Vote model validates accepted/preferred as 0 or 1)
        vote.accepted = accept_value ? 1 : 0
        vote.preferred = prefer_value ? 1 : 0
        vote.save!
        track_task_run_resource(vote, action_type: "vote")
        votes << vote
      end

      if current_representation_session
        current_representation_session.record_events!(
          request: request,
          action_name: "vote",
          resources: votes,
          context_resource: current_decision
        )
      end
    end
    votes
  end

  sig { returns(User) }
  def create_ai_agent
    # Only AI agent users can be created via the API
    user = T.let(nil, T.nilable(User))
    ActiveRecord::Base.transaction do
      agent_config = {}
      agent_config["identity_prompt"] = params[:identity_prompt] if params[:identity_prompt].present?

      # Handle mode - internal (Harmonic-powered) or external (API key required)
      mode = params[:mode]
      agent_config["mode"] = %w[internal external].include?(mode) ? mode : "external"

      # Handle capabilities - filter to only valid grantable actions
      capabilities = params[:capabilities]
      if capabilities.is_a?(Array) && capabilities.any?
        valid_caps = capabilities & CapabilityCheck::AI_AGENT_GRANTABLE_ACTIONS
        agent_config["capabilities"] = valid_caps
      else
        # All boxes unchecked or no capabilities param = empty array (nothing allowed except defaults)
        agent_config["capabilities"] = []
      end

      # Handle model selection for internal AI agents
      agent_config["model"] = params[:model] if params[:model].present?

      user = User.create!(
        name: params[:name],
        email: SecureRandom.uuid + "@not-a-real-email.com",
        user_type: "ai_agent",
        parent_id: current_user.id,
        agent_configuration: agent_config,
      )
      tenant_user = current_tenant.add_user!(user)
      user.tenant_user = tenant_user
    end
    T.must(user)
  end

  sig { params(user: User).returns(ApiToken) }
  def generate_token(user)
    ApiToken.create!(
      name: "#{user.display_name}'s API Token",
      user: user,
      expires_at: 1.year.from_now,
      scopes: ApiToken.read_scopes + ApiToken.write_scopes,
    )
  end

  sig { returns(T.nilable(Note)) }
  def current_note
    return @current_note if @current_note
    return nil unless @current_resource_model == Note && @current_resource.is_a?(Note)
    @current_resource
  end

  sig { returns(T.nilable(Decision)) }
  def current_decision
    return @current_decision if @current_decision
    return nil unless @current_resource_model == Decision && @current_resource.is_a?(Decision)
    @current_resource
  end

  sig { returns(T.nilable(Commitment)) }
  def current_commitment
    return @current_commitment if @current_commitment
    return nil unless @current_resource_model == Commitment && @current_resource.is_a?(Commitment)
    @current_resource
  end

  sig { returns(T.nilable(DecisionParticipant)) }
  def current_decision_participant
    return @current_decision_participant if @current_decision_participant
    if @current_resource_model == DecisionParticipant && @current_resource.is_a?(DecisionParticipant)
      @current_resource
    else
      @current_decision_participant = DecisionParticipantManager.new(
        decision: T.must(current_decision),
        user: current_user,
      ).find_or_create_participant
    end
    @current_decision_participant
  end

  sig { returns(T.nilable(CommitmentParticipant)) }
  def current_commitment_participant
    return @current_commitment_participant if @current_commitment_participant
    return nil unless @current_resource_model == CommitmentParticipant && @current_resource.is_a?(CommitmentParticipant)
    @current_resource
  end

  sig { returns(T.nilable(Option)) }
  def current_option
    return @current_option if defined?(@current_option) && @current_option
    if params[:option_id]
      @current_option = T.let(T.must(current_decision).options.find_by(id: params[:option_id]), T.nilable(Option))
    elsif params[:option_title]
      # Option title is unique per decision, so we can use it to find the option.
      @current_option = T.let(T.must(current_decision).options.find_by(title: params[:option_title]), T.nilable(Option))
    elsif @current_resource_model == Option && @current_resource.is_a?(Option)
      @current_option = T.let(@current_resource, T.nilable(Option))
    end
    @current_option
  end

  sig { params(invite: T.nilable(Invite)).returns(SuperagentMember) }
  def join_studio(invite: nil)
    raise 'User is already a member of this studio' if current_user.superagents.include?(current_superagent)

    superagent_member = T.let(nil, T.nilable(SuperagentMember))
    ActiveRecord::Base.transaction do
      if invite
        raise 'Invite does not match studio' unless invite.superagent == current_superagent
        current_user.accept_invite!(invite)
        superagent_member = current_user.superagent_members.find_by(superagent: current_superagent)
      elsif current_superagent.is_scene?
        # Scenes allow direct join without invite
        current_superagent.add_user!(current_user)
        superagent_member = current_user.superagent_members.find_by(superagent: current_superagent)
      else
        raise 'Valid invite required to join this studio'
      end

    end
    T.must(superagent_member)
  end

  sig { returns(Superagent) }
  def update_studio_settings
    raise 'Unauthorized: must be admin' unless current_user.superagent_member&.is_admin?

    ActiveRecord::Base.transaction do
      current_superagent.name = params[:name] if params[:name].present?
      current_superagent.description = params[:description] if params[:description].present?
      current_superagent.timezone = params[:timezone] if params[:timezone].present?
      current_superagent.tempo = params[:tempo] if params[:tempo].present?
      current_superagent.synchronization_mode = params[:synchronization_mode] if params[:synchronization_mode].present?

      # Handle settings stored in JSON column
      if params.has_key?(:invitations)
        current_superagent.settings['all_members_can_invite'] = params[:invitations] == 'all_members'
      end
      if params.has_key?(:representation)
        current_superagent.settings['any_member_can_represent'] = params[:representation] == 'any_member'
      end
      if params.has_key?(:file_uploads)
        # Use unified feature flag system
        enabled = params[:file_uploads] == true || params[:file_uploads] == "true" || params[:file_uploads] == "1"
        current_superagent.settings["feature_flags"] ||= {}
        current_superagent.settings["feature_flags"]["file_attachments"] = enabled
      end
      # api_enabled is intentionally not changeable via API:
      # - Can't enable if already disabled (no API access)
      # - Can't disable (would lock out the caller)
      # Use HTML UI to change this setting

      current_superagent.updated_by = current_user
      current_superagent.save!

    end
    current_superagent
  end

  sig { params(grant: TrusteeGrant).returns(RepresentationSession) }
  def start_user_representation_session(grant:)
    raise ArgumentError, "Grant must be active" unless grant.active?
    raise ArgumentError, "Current user must be the trustee" unless grant.trustee_user == current_user

    rep_session = RepresentationSession.create!(
      tenant: current_tenant,
      superagent_id: nil,
      representative_user: current_user,
      trustee_grant: grant,
      confirmed_understanding: true,
      began_at: Time.current,
    )
    rep_session.begin!
    rep_session
  end

  sig { returns(Decision) }
  def update_decision_settings
    decision = T.must(current_decision)
    raise 'Unauthorized: only creator can edit settings' unless decision.can_edit_settings?(current_user)

    ActiveRecord::Base.transaction do
      decision.question = params[:question] if params[:question].present?
      decision.description = params[:description] if params[:description].present?
      # options_open is a boolean, so we need to check has_key? AND the value is not nil
      if params.has_key?(:options_open) && !params[:options_open].nil?
        decision.options_open = params[:options_open]
      end
      decision.deadline = params[:deadline] if params[:deadline].present?

      decision.save!

      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: "update_decision_settings",
          resource: decision
        )
      end
    end
    decision
  end

  sig { returns(Commitment) }
  def update_commitment_settings
    commitment = T.must(current_commitment)
    raise 'Unauthorized: only creator can edit settings' unless commitment.can_edit_settings?(current_user)

    ActiveRecord::Base.transaction do
      commitment.title = params[:title] if params[:title].present?
      commitment.description = params[:description] if params[:description].present?

      if params[:critical_mass].present?
        new_cm = params[:critical_mass].to_i
        if new_cm < commitment.critical_mass.to_i && commitment.participant_count > 0
          raise 'Cannot lower critical mass after participants have joined'
        end
        commitment.critical_mass = new_cm
      end

      commitment.deadline = params[:deadline] if params[:deadline].present?
      commitment.save!

      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: "update_commitment_settings",
          resource: commitment
        )
      end
    end
    commitment
  end

  # Pin a resource (Note, Decision, or Commitment)
  sig { params(resource: T.any(Note, Decision, Commitment)).returns(T.any(Note, Decision, Commitment)) }
  def pin_resource(resource)
    resource.pin!(tenant: current_tenant, superagent: current_superagent, user: current_user)
    if current_representation_session
      action_name = "pin_#{T.must(resource.class.name).underscore}"
      current_representation_session.record_event!(
        request: request,
        action_name: action_name,
        resource: resource
      )
    end
    resource
  end

  # Unpin a resource (Note, Decision, or Commitment)
  sig { params(resource: T.any(Note, Decision, Commitment)).returns(T.any(Note, Decision, Commitment)) }
  def unpin_resource(resource)
    resource.unpin!(tenant: current_tenant, superagent: current_superagent, user: current_user)
    if current_representation_session
      action_name = "unpin_#{T.must(resource.class.name).underscore}"
      current_representation_session.record_event!(
        request: request,
        action_name: action_name,
        resource: resource
      )
    end
    resource
  end

  # Update option title
  sig { params(option: Option).returns(Option) }
  def update_option(option)
    ActiveRecord::Base.transaction do
      option.title = params[:title] if params[:title].present?
      option.save!
      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: "update_option",
          resource: option,
          context_resource: option.decision
        )
      end
    end
    option
  end

  # Delete an option
  sig { params(option: Option).void }
  def delete_option(option)
    decision = option.decision
    ActiveRecord::Base.transaction do
      option.destroy!
      # Note: We don't record an event for deleted resources since the resource no longer exists
    end
  end

  # Duplicate a decision
  sig { returns(Decision) }
  def duplicate_decision
    original = T.must(current_decision)
    new_decision = T.let(nil, T.nilable(Decision))
    ActiveRecord::Base.transaction do
      new_decision = Decision.create!(
        question: "#{original.question} (copy)",
        description: original.description,
        options_open: original.options_open,
        deadline: original.deadline,
        created_by: current_user,
      )
      original.options.each do |opt|
        Option.create!(
          decision: new_decision,
          title: opt.title,
          decision_participant: DecisionParticipantManager.new(
            decision: new_decision,
            user: current_user
          ).find_or_create_participant,
        )
      end
      track_task_run_resource(new_decision, action_type: "create")
      if current_representation_session
        current_representation_session.record_event!(
          request: request,
          action_name: "create_decision",
          resource: new_decision
        )
      end
    end
    T.must(new_decision)
  end

  private

  # Track resources created during an AiAgentTaskRun for traceability
  sig { params(resource: T.untyped, action_type: String).void }
  def track_task_run_resource(resource, action_type:)
    return unless AiAgentTaskRun.current_id
    return unless resource.respond_to?(:superagent_id) && resource.superagent_id.present?

    AiAgentTaskRunResource.create!(
      ai_agent_task_run_id: AiAgentTaskRun.current_id,
      resource: resource,
      resource_superagent_id: resource.superagent_id,
      action_type: action_type,
      display_path: compute_display_path(resource),
    )
  rescue ActiveRecord::RecordInvalid => e
    # Log but don't fail the main operation
    Rails.logger.warn("Failed to track task run resource: #{e.message}")
  end

  # Compute the linkable path for a resource at creation time
  # (avoids scoping issues when displaying later)
  sig { params(resource: T.untyped).returns(T.nilable(String)) }
  def compute_display_path(resource)
    # Use unscoped queries to handle cross-superagent resources
    tenant_id = resource.tenant_id
    case resource
    when Note, Decision, Commitment
      resource.path
    when Option
      decision = Decision.tenant_scoped_only(tenant_id).find_by(id: resource.decision_id)
      decision&.path
    when Vote
      option = Option.tenant_scoped_only(tenant_id).find_by(id: resource.option_id)
      return nil unless option
      decision = Decision.tenant_scoped_only(tenant_id).find_by(id: option.decision_id)
      decision&.path
    when NoteHistoryEvent
      note = Note.tenant_scoped_only(tenant_id).find_by(id: resource.note_id)
      note&.path
    when CommitmentParticipant
      commitment = Commitment.tenant_scoped_only(tenant_id).find_by(id: resource.commitment_id)
      commitment&.path
    else
      nil
    end
  end

end
