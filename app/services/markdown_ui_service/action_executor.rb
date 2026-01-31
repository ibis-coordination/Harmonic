# typed: true

# Handles action execution for the MarkdownUiService.
#
# ActionExecutor maps action names to execution methods and delegates to
# {ApiHelper} for the actual business logic. This ensures consistent behavior
# between HTTP API calls and internal service calls.
#
# Supported action categories:
# - **Note actions**: create_note, confirm_read, edit_note, pin_note, unpin_note
# - **Decision actions**: create_decision, vote, edit_settings, pin/unpin
# - **Commitment actions**: create_commitment, join, leave, edit_settings, pin/unpin
# - **Studio actions**: create_studio, join_studio, leave_studio, update_settings, send_heartbeat
# - **Notification actions**: mark_read, dismiss, mark_all_read
#
# @example Executing an action
#   executor = ActionExecutor.new(
#     service: service,
#     view_context: context,
#     action_name: "create_note",
#     params: { text: "Hello world" }
#   )
#   result = executor.execute
#   # => { success: true, content: "Note created: /studios/team/n/abc", error: nil }
#
# @see ApiHelper For the underlying business logic
# @see ActionsHelper For action definitions and available actions per route
#
class MarkdownUiService
  class ActionExecutor
    extend T::Sig

    sig { returns(MarkdownUiService) }
    attr_reader :service

    sig { returns(MarkdownUiService::ViewContext) }
    attr_reader :view_context

    sig { returns(String) }
    attr_reader :action_name

    sig { returns(T::Hash[Symbol, T.untyped]) }
    attr_reader :params

    sig do
      params(
        service: MarkdownUiService,
        view_context: MarkdownUiService::ViewContext,
        action_name: String,
        params: T::Hash[Symbol, T.untyped]
      ).void
    end
    def initialize(service:, view_context:, action_name:, params:)
      @service = service
      @view_context = view_context
      @action_name = action_name
      @params = params
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute
      # Check if action exists
      action_def = ActionsHelper.action_definition(action_name)
      return error_result("Unknown action: #{action_name}") unless action_def

      # Defense-in-depth: Check authorization before execution
      # This ensures actions are denied even if controller authorization is bypassed
      context = build_authorization_context
      unless ActionAuthorization.authorized?(action_name, view_context.current_user, context)
        return error_result("Not authorized to execute action: #{action_name}")
      end

      # Execute the action
      case action_name
      # Note actions
      when "create_note"
        execute_create_note
      when "update_note"
        execute_update_note
      when "confirm_read"
        execute_confirm_read
      when "pin_note"
        execute_pin_note
      when "unpin_note"
        execute_unpin_note
      when "add_comment"
        execute_add_comment

      # Decision actions
      when "create_decision"
        execute_create_decision
      when "update_decision_settings"
        execute_update_decision_settings
      when "add_option"
        execute_add_option
      when "vote"
        execute_vote
      when "pin_decision"
        execute_pin_decision
      when "unpin_decision"
        execute_unpin_decision

      # Commitment actions
      when "create_commitment"
        execute_create_commitment
      when "update_commitment_settings"
        execute_update_commitment_settings
      when "join_commitment"
        execute_join_commitment
      when "pin_commitment"
        execute_pin_commitment
      when "unpin_commitment"
        execute_unpin_commitment

      # Studio actions
      when "create_studio"
        execute_create_studio
      when "join_studio"
        execute_join_studio
      when "update_studio_settings"
        execute_update_studio_settings
      when "send_heartbeat"
        execute_send_heartbeat

      # Notification actions
      when "mark_read"
        execute_mark_read
      when "dismiss"
        execute_dismiss
      when "mark_all_read"
        execute_mark_all_read

      else
        error_result("Action not implemented: #{action_name}")
      end
    rescue ActiveRecord::RecordInvalid => e
      error_result("Validation error: #{e.message}")
    rescue StandardError => e
      error_result("Action failed: #{e.message}")
    end

    private

    # Build context for ActionAuthorization checks.
    # Includes studio, resource, and target_user based on current view context.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def build_authorization_context
      {
        studio: view_context.current_superagent,
        resource: current_resource,
        target_user: view_context.current_user, # For user settings pages
        target: view_context.current_user, # For representative checks
      }
    end

    sig { returns(ApiHelper) }
    def api_helper
      @api_helper ||= ApiHelper.new(
        current_user: T.must(view_context.current_user),
        current_superagent: view_context.current_superagent,
        current_tenant: view_context.current_tenant,
        current_resource_model: current_resource_model,
        current_resource: current_resource,
        current_note: view_context.note,
        current_decision: view_context.decision,
        current_commitment: view_context.commitment,
        current_decision_participant: view_context.decision_participant,
        current_commitment_participant: view_context.commitment_participant,
        current_cycle: view_context.current_cycle,
        current_heartbeat: view_context.current_heartbeat,
        params: params.with_indifferent_access
      )
    end

    sig { returns(T.nilable(T::Class[T.anything])) }
    def current_resource_model
      if view_context.note
        Note
      elsif view_context.decision
        Decision
      elsif view_context.commitment
        Commitment
      end
    end

    sig { returns(T.untyped) }
    def current_resource
      view_context.note || view_context.decision || view_context.commitment
    end

    # Note actions

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_create_note
      note = api_helper.create_note
      success_result("Note created", note)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_update_note
      note = api_helper.update_note
      success_result("Note updated", note)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_confirm_read
      api_helper.confirm_read
      success_result("Read confirmed", view_context.note)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_pin_note
      note = T.must(view_context.note)
      view_context.current_superagent.pin_item!(note)
      success_result("Note pinned", note)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_unpin_note
      note = T.must(view_context.note)
      view_context.current_superagent.unpin_item!(note)
      success_result("Note unpinned", note)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_add_comment
      commentable = current_resource
      raise "No resource to comment on" unless commentable
      note = api_helper.create_note(commentable: commentable)
      success_result("Comment added", note)
    end

    # Decision actions

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_create_decision
      decision = api_helper.create_decision
      success_result("Decision created", decision)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_update_decision_settings
      decision = T.must(view_context.decision)
      decision.update!(
        question: params[:question] || decision.question,
        description: params[:description] || decision.description,
        options_open: params.key?(:options_open) ? params[:options_open] : decision.options_open,
        deadline: params[:deadline] || decision.deadline
      )
      success_result("Decision updated", decision)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_add_option
      decision = T.must(view_context.decision)
      option = decision.options.create!(
        title: params[:title],
        created_by: view_context.current_user
      )
      success_result("Option added", decision)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_vote
      api_helper.vote
      success_result("Vote recorded", view_context.decision)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_pin_decision
      decision = T.must(view_context.decision)
      view_context.current_superagent.pin_item!(decision)
      success_result("Decision pinned", decision)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_unpin_decision
      decision = T.must(view_context.decision)
      view_context.current_superagent.unpin_item!(decision)
      success_result("Decision unpinned", decision)
    end

    # Commitment actions

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_create_commitment
      commitment = api_helper.create_commitment
      success_result("Commitment created", commitment)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_update_commitment_settings
      commitment = T.must(view_context.commitment)
      commitment.update!(
        title: params[:title] || commitment.title,
        description: params[:description] || commitment.description,
        critical_mass: params[:critical_mass] || commitment.critical_mass,
        deadline: params[:deadline] || commitment.deadline
      )
      success_result("Commitment updated", commitment)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_join_commitment
      commitment = T.must(view_context.commitment)
      participant = CommitmentParticipantManager.new(
        commitment: commitment,
        user: view_context.current_user
      ).find_or_create_participant
      T.unsafe(participant).join!
      success_result("Joined commitment", commitment)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_pin_commitment
      commitment = T.must(view_context.commitment)
      view_context.current_superagent.pin_item!(commitment)
      success_result("Commitment pinned", commitment)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_unpin_commitment
      commitment = T.must(view_context.commitment)
      view_context.current_superagent.unpin_item!(commitment)
      success_result("Commitment unpinned", commitment)
    end

    # Studio actions

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_create_studio
      studio = api_helper.create_studio
      success_result("Studio created", studio)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_join_studio
      superagent = view_context.current_superagent
      user = T.must(view_context.current_user)
      superagent.add_user!(user)
      success_result("Joined studio", superagent)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_update_studio_settings
      superagent = view_context.current_superagent
      superagent.update!(
        name: params[:name] || superagent.name,
        description: params[:description] || superagent.description,
        timezone: params[:timezone] || superagent.timezone.name,
        tempo: params[:tempo] || superagent.tempo,
        synchronization_mode: params[:synchronization_mode] || superagent.synchronization_mode
      )
      success_result("Studio settings updated", superagent)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_send_heartbeat
      heartbeat = api_helper.create_heartbeat
      success_result("Heartbeat sent", heartbeat)
    end

    # Notification actions

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_mark_read
      recipient_id = params[:id]
      raise "Missing notification ID" unless recipient_id
      recipient = NotificationRecipient.find(recipient_id)
      T.unsafe(recipient).mark_read!
      success_result("Notification marked as read", nil)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_dismiss
      recipient_id = params[:id]
      raise "Missing notification ID" unless recipient_id
      recipient = NotificationRecipient.find(recipient_id)
      T.unsafe(recipient).dismiss!
      success_result("Notification dismissed", nil)
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def execute_mark_all_read
      user = T.must(view_context.current_user)
      NotificationRecipient.where(user: user, read_at: nil).update_all(read_at: Time.current)
      success_result("All notifications marked as read", nil)
    end

    # Result helpers

    sig { params(message: String, resource: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
    def success_result(message, resource)
      content = "#{message}"
      content += " at #{resource.path}" if resource.respond_to?(:path)
      {
        success: true,
        content: content,
        error: nil,
      }
    end

    sig { params(message: String).returns(T::Hash[Symbol, T.untyped]) }
    def error_result(message)
      {
        success: false,
        content: "",
        error: message,
      }
    end
  end
end
