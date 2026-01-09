# typed: true
# frozen_string_literal: true

module Mcp
  module Tools
    DEFINITIONS = [
      {
        "name" => "navigate",
        "description" => "Navigate to a URL in Harmonic and see its content and available actions. " \
                         "Returns markdown content plus a list of actions you can take on this page. " \
                         "URLs can be shared with humans—they see the same page in their browser. " \
                         "Examples: '/studios/team', '/studios/team/d/abc123', '/studios/team/cycles/today'",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "url" => {
              "type" => "string",
              "description" => "Relative URL path (e.g., '/studios/team/n/abc123')",
            },
          },
          "required" => ["url"],
        },
      },
      {
        "name" => "execute_action",
        "description" => "Execute an action available at the current URL. " \
                         "You must call 'navigate' first to see available actions. " \
                         "Actions are contextual—only actions listed for the current page will work.",
        "inputSchema" => {
          "type" => "object",
          "properties" => {
            "action" => {
              "type" => "string",
              "description" => "Action name from the available actions list",
            },
            "params" => {
              "type" => "object",
              "description" => "Parameters for the action (see action's parameter list)",
              "additionalProperties" => true,
            },
          },
          "required" => ["action"],
        },
      },
    ].freeze
  end
end
