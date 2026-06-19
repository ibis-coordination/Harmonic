# typed: true
# frozen_string_literal: true

# Classifies an agent action's audience as "public" (tenant main collective),
# "private" (acting agent is the only viewer), or "shared" (everyone else).
# Ground truth for the ActionContext visibility gate.
#
# The tier lives on the action's entry in `ActionsHelper::ACTION_DEFINITIONS`
# under the `:visibility` key — same pattern as `:authorization`. Co-locating
# visibility with the action prevents drift: adding a new action forces the
# author to declare its tier in the same place they declare description /
# params / authorization, instead of remembering to update a parallel list
# kept somewhere else.
module Mcp
  class AudienceResolver
    extend T::Sig

    # Symbolic resolvers. Each takes the resolved collective and returns one
    # of "public" / "private" / "shared". Actions whose tier doesn't fit any
    # of these can declare a Proc with the same signature.
    RESOLVERS = T.let({
      public: ->(_collective) { "public" },
      private: ->(_collective) { "private" },
      shared: ->(_collective) { "shared" },
      by_collective: lambda { |collective|
        # :by_collective is only meaningful when there's a collective in
        # context — actions that can be invoked without one should declare a
        # static tier instead. Raise rather than silently picking a default;
        # a nil collective here means the caller is misconfigured.
        raise ArgumentError, ":by_collective resolver called with no collective" if collective.nil?

        if collective.is_main_collective?
          "public"
        elsif collective.private_workspace?
          "private"
        else
          "shared"
        end
      },
    }.freeze, T::Hash[Symbol, T.untyped])

    sig do
      params(
        capability_action: T.nilable(String),
        collective: T.nilable(Collective)
      ).returns(String)
    end
    def self.resolve(capability_action:, collective:)
      visibility = lookup_visibility(capability_action)
      call_resolver(visibility, collective, capability_action)
    end

    sig { params(capability_action: T.nilable(String)).returns(T.untyped) }
    def self.lookup_visibility(capability_action)
      return :by_collective if capability_action.nil?

      definition = ActionsHelper.action_definition(capability_action)
      definition&.dig(:visibility) || :by_collective
    end
    private_class_method :lookup_visibility

    sig do
      params(
        visibility: T.untyped,
        collective: T.nilable(Collective),
        capability_action: T.nilable(String)
      ).returns(String)
    end
    def self.call_resolver(visibility, collective, capability_action)
      return visibility.call(collective) if visibility.is_a?(Proc)

      resolver = RESOLVERS[visibility]
      return resolver.call(collective) if resolver

      raise ArgumentError,
            "Unknown :visibility #{visibility.inspect} on action #{capability_action.inspect} " \
            "(expected one of :public, :private, :shared, :by_collective, or a Proc)"
    end
    private_class_method :call_resolver
  end
end
