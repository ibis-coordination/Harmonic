# typed: false
# frozen_string_literal: true

# Helper methods for markdown views
module MarkdownHelper
  # Get the available actions for the current route.
  # Returns an array of action hashes with name, description, path, and params.
  # Includes both static actions and conditional actions whose conditions are met.
  def available_actions_for_current_route
    route_pattern = build_route_pattern_from_request
    return [] unless route_pattern

    route_info = ActionsHelper.actions_for_route(route_pattern)
    return [] unless route_info

    # Combine static actions with conditional actions that pass their condition
    all_actions = (route_info[:actions] || []) + evaluate_conditional_actions(route_info)

    # Filter by capability for ai_agents
    current_user = instance_variable_get(:@current_user)
    all_actions = all_actions.select { |a| CapabilityCheck.allowed?(current_user, a[:name]) } if current_user&.ai_agent?

    # Build full action info with path and params
    all_actions.map do |action|
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

  # Evaluate conditional actions and return those whose conditions are met.
  # Builds a context hash from instance variables for condition evaluation.
  def evaluate_conditional_actions(route_info)
    conditional_actions = route_info[:conditional_actions] || []
    return [] if conditional_actions.empty?

    # Build context from common instance variables
    context = build_condition_context

    conditional_actions.select do |conditional_action|
      condition = conditional_action[:condition]
      next false unless condition.respond_to?(:call)

      begin
        condition.call(context)
      rescue StandardError
        false
      end
    end
  end

  # Build a context hash from instance variables for conditional action evaluation.
  # Add commonly needed variables here as the conditional actions system grows.
  def build_condition_context
    {
      superagent: instance_variable_get(:@current_superagent),
      current_heartbeat: instance_variable_get(:@current_heartbeat),
      user: instance_variable_get(:@current_user),
      tenant: instance_variable_get(:@current_tenant),
      resource: instance_variable_get(:@resource),
    }
  end
end
