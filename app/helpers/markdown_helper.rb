# typed: false
# frozen_string_literal: true

# Helper methods for markdown views
module MarkdownHelper
  # Get the available actions for the current route.
  # Returns an array of action hashes with name, description, path, and params.
  def available_actions_for_current_route
    route_pattern = build_route_pattern_from_request
    return [] unless route_pattern

    route_info = ActionsHelper.actions_for_route(route_pattern)
    return [] unless route_info

    actions = route_info[:actions] || []

    # Build full action info with path and params
    actions.map do |action|
      action_name = action[:name]
      definition = ActionsHelper.action_definition(action_name)

      {
        name: action_name,
        description: action[:description] || definition&.dig(:description) || "",
        path: "#{request.path}/actions/#{action_name}",
        params: (definition&.dig(:params) || []).map do |param|
          {
            name: param[:name],
            type: param[:type] || "string",
            required: param[:required] != false,
            description: param[:description],
          }
        end,
      }
    end
  end

  private

  # Build the route pattern from the current request.
  # Uses ActionsHelper.route_pattern_for as the single source of truth.
  def build_route_pattern_from_request
    controller_action = "#{params[:controller]}##{params[:action]}"
    ActionsHelper.route_pattern_for(controller_action)
  end
end
