# typed: true
# frozen_string_literal: true

# Classifies an agent action's audience as "public" (tenant main collective),
# "private" (acting agent is the only viewer), or "shared" (everyone else).
# Ground truth for the ActionContext visibility gate.
module Mcp
  class AudienceResolver
    extend T::Sig

    # Actions whose result is only ever visible to the acting agent: their own
    # scratchpad, their own inbox. Stay private regardless of which collective
    # the request scopes to.
    AGENT_PRIVATE_ACTIONS = Set[
      "update_scratchpad",
      "dismiss",
      "dismiss_all",
      "dismiss_for_collective",
      "mark_read",
    ].freeze

    sig { params(capability_action: T.nilable(String), collective: T.nilable(Collective)).returns(String) }
    def self.resolve(capability_action:, collective:)
      return "private" if capability_action && AGENT_PRIVATE_ACTIONS.include?(capability_action)
      return "shared" unless collective

      collective.is_main_collective? ? "public" : "shared"
    end
  end
end
