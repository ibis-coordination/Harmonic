# typed: true
# frozen_string_literal: true

module Mcp
  # Maintains navigation context within an MCP session
  class NavigationState
    extend T::Sig

    sig { returns(T.nilable(String)) }
    attr_reader :current_url

    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    attr_reader :available_actions

    sig { void }
    def initialize
      @current_url = nil
      @available_actions = []
    end

    sig { params(url: String, actions: T::Array[T::Hash[Symbol, T.untyped]]).void }
    def navigate(url, actions)
      @current_url = url
      @available_actions = actions
    end

    sig { params(name: String).returns(T::Boolean) }
    def action_available?(name)
      @available_actions.any? { |a| a[:name].to_s == name }
    end

    sig { params(name: String).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
    def find_action(name)
      @available_actions.find { |a| a[:name].to_s == name }
    end
  end
end
