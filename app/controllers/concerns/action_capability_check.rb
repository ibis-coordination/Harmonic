# typed: false

# ActionCapabilityCheck provides execution-time capability checking for AI agent actions.
#
# This concern is a defense-in-depth measure that blocks unauthorized actions
# even if they somehow bypass the action listing filter (e.g., cached pages,
# guessed URLs, or direct API calls).
#
# It handles three types of routes:
# 1. Explicit /actions/{action_name} routes (extracted from path)
# 2. Legacy HTML form routes (mapped via CONTROLLER_ACTION_MAP)
# 3. REST API v1 routes (mapped via CONTROLLER_ACTION_MAP)
#
# @see CapabilityCheck for the core capability logic
# @see MarkdownHelper#available_actions_for_current_route for listing-time filtering
module ActionCapabilityCheck
  extend ActiveSupport::Concern

  # Writes exempt from the unmapped-write fail-closed below. These are
  # session-management routes whose controllers enforce "the acting user is
  # the session's representative_user" — meaning whoever started the session
  # can end it. Running the capability layer on top of
  # that would let an unrelated capability configuration prevent a user
  # from ending a session they started.
  SESSION_MANAGEMENT_WRITES = Set.new([
    "users#stop_representing",                         # DELETE /u/:handle/represent
    "representation_sessions#stop_representing",       # DELETE /collectives/:handle/represent
    "representation_sessions#stop_representing_user",  # DELETE /representing
  ]).freeze

  # Maps controller#action to capability action names.
  # This catches legacy HTML routes and REST API routes that don't use /actions/ paths.
  #
  # Format: "controller#action" => "capability_name"
  CONTROLLER_ACTION_MAP = {
    # Notes - legacy HTML routes
    "notes#create" => "create_note",
    "notes#update" => "update_note",
    "notes#create_comment" => "add_comment",
    "notes#confirm_and_return_partial" => "confirm_read",

    # Notes - API v1 routes
    "api/v1/notes#create" => "create_note",
    "api/v1/notes#update" => "update_note",
    "api/v1/notes#confirm" => "confirm_read",

    # Decisions - legacy HTML routes
    "decisions#create" => "create_decision",
    "decisions#create_comment" => "add_comment",
    "decisions#create_option_and_return_options_partial" => "add_options",
    "decisions#update_settings" => "update_decision_settings",
    "decisions#duplicate" => "create_decision",

    # Decisions - API v1 routes
    "api/v1/decisions#create" => "create_decision",
    "api/v1/decisions#update" => "update_decision_settings",

    # Votes - API v1 routes
    "api/v1/votes#create" => "vote",
    "api/v1/votes#update" => "vote",

    # Options - API v1 routes
    "api/v1/options#create" => "add_options",

    # Commitments - legacy HTML routes
    "commitments#create" => "create_commitment",
    "commitments#create_comment" => "add_comment",
    "commitments#join_and_return_partial" => "join_commitment",
    "commitments#update_settings" => "update_commitment_settings",
    "commitments#join" => "join_commitment",

    # Commitments - API v1 routes
    "api/v1/commitments#create" => "create_commitment",
    "api/v1/commitments#update" => "update_commitment_settings",
    "api/v1/commitments#join" => "join_commitment",

    # Collectives - legacy HTML routes
    "collectives#create" => "create_collective",
    "collectives#update_settings" => "update_collective_settings",
    "collectives#add_ai_agent" => "add_ai_agent_to_collective",
    "collectives#accept_invite" => "join_collective",

    # Collectives - API v1 routes
    "api/v1/collectives#create" => "create_collective",
    "api/v1/collectives#update" => "update_collective_settings",

    # Users - legacy HTML routes
    "users#update_profile" => "update_profile",
    "users#add_ai_agent_to_collective" => "add_ai_agent_to_collective",
  }.freeze

  included do
    # Use append_before_action to ensure this runs AFTER all other before_actions,
    # particularly after current_user is set by ApplicationController's before_action chain
    append_before_action :check_capability_for_action
  end

  private

  def check_capability_for_action
    # Skip if no user is authenticated
    return unless defined?(@current_user) && @current_user.present?

    capability_action = determine_capability_action

    # Fail-closed on unmapped writes for users subject to CapabilityCheck.
    #
    # `determine_capability_action` returns nil when the route is neither an
    # `/actions/<name>` dispatch nor listed in CONTROLLER_ACTION_MAP, so we
    # have no action name to feed CapabilityCheck. Silently skipping would
    # let a capability-restricted caller reach writes through unmapped
    # routes. Deny instead. Callers not restricted by CapabilityCheck
    # (see CapabilityCheck#allowed?) aren't affected. GETs aren't affected.
    #
    # SESSION_MANAGEMENT_WRITES are the exception — see the set's comment.
    #
    # This is coarse; a follow-up plan (.claude/plans/agent-capability-audit.md)
    # covers populating the map exhaustively or refactoring to deny-by-default
    # universally.
    if capability_action.blank?
      return unless write_request?
      return if SESSION_MANAGEMENT_WRITES.include?("#{controller_path}##{action_name}")
      return unless CapabilityCheck.restricted_user?(@current_user)

      render_capability_denied("unmapped_write:#{controller_path}##{action_name}")
      return
    end

    return if CapabilityCheck.allowed?(@current_user, capability_action)

    render_capability_denied(capability_action)
  end

  def write_request?
    request.post? || request.patch? || request.put? || request.delete?
  end

  # Determines the capability action name from the request.
  # Checks /actions/ path first, then falls back to controller#action mapping.
  def determine_capability_action
    # Check explicit /actions/ routes first (POST only)
    return extract_action_name_from_path if request.path.include?("/actions/") && request.post?

    # Check controller#action mapping for write operations (POST, PATCH, PUT, DELETE)
    return nil unless request.post? || request.patch? || request.put? || request.delete?

    # Use controller_path and action_name (Rails methods) to build the key
    controller_action_key = "#{controller_path}##{action_name}"
    CONTROLLER_ACTION_MAP[controller_action_key]
  end

  def extract_action_name_from_path
    match = request.path.match(%r{/actions/([^/]+)})
    match[1] if match
  end

  def render_capability_denied(action_name)
    error_message = "Your capabilities do not include '#{action_name}'"

    respond_to do |format|
      format.md { render plain: "Error: #{error_message}", status: :forbidden }
      format.html { render plain: "Forbidden: #{error_message}", status: :forbidden }
      format.json { render json: { error: error_message }, status: :forbidden }
    end
  end
end
