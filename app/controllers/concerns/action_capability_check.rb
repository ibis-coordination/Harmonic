# typed: false

# ActionCapabilityCheck provides execution-time capability checking for subagent actions.
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

    # Studios - legacy HTML routes
    "studios#create" => "create_studio",
    "studios#update_settings" => "update_studio_settings",
    "studios#add_subagent" => "add_subagent_to_studio",
    "studios#accept_invite" => "join_studio",

    # Studios - API v1 routes
    "api/v1/studios#create" => "create_studio",
    "api/v1/studios#update" => "update_studio_settings",

    # Users - legacy HTML routes
    "users#update_profile" => "update_profile",
    "users#add_subagent_to_studio" => "add_subagent_to_studio",
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

    # Determine the capability action name from the request
    capability_action = determine_capability_action
    return if capability_action.blank?

    return if CapabilityCheck.allowed?(@current_user, capability_action)

    render_capability_denied(capability_action)
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
