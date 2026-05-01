# typed: true

# CapabilityCheck provides capability-based authorization for AI agent actions.
#
# This module determines which actions an AI agent can perform based on:
# 1. Always-allowed infrastructure actions (essential for navigation)
# 2. Grantable actions (configurable by the agent owner)
# 3. Always-blocked actions (never allowed for AI agents)
#
# If capabilities key is absent (nil), all grantable actions are allowed (backwards compatible default).
# If capabilities is an empty array, NO grantable actions are allowed.
# If capabilities has items, only those listed grantable actions are permitted.
#
# @see ActionAuthorization for base authorization checks
module CapabilityCheck
  extend T::Sig

  # Actions that AI agents can always perform (infrastructure)
  # These are essential for navigation and basic app operation
  AI_AGENT_ALWAYS_ALLOWED = [
    "send_heartbeat",
    "dismiss",
    "dismiss_all",
    "dismiss_for_collective",
    "search",
    "update_scratchpad",
  ].freeze

  # Actions that AI agents can never perform
  # These are sensitive operations that should only be done by humans
  AI_AGENT_ALWAYS_BLOCKED = [
    "create_collective",
    "join_collective",
    "update_collective_settings",
    "create_ai_agent",
    "add_ai_agent_to_collective",
    "remove_ai_agent_from_collective",
    "create_api_token",
    "update_profile",
    "create_webhook",
    "update_webhook",
    "delete_webhook",
    "test_webhook",
    "suspend_user",
    "unsuspend_user",
    "update_tenant_settings",
    "create_tenant",
    "retry_sidekiq_job",
    # Automation rule management is owner-scoped; agents should not be
    # self-modifying their trigger graph. (HUMAN_ONLY_AUTHORIZATION already
    # blocks these at the action-authorization layer, but listing them here
    # makes the policy explicit and test-auditable.)
    "create_automation_rule",
    "update_automation_rule",
    "delete_automation_rule",
    "toggle_automation_rule",
  ].freeze

  # Actions that can be granted/denied via configuration
  # The owner can allow or deny these actions for their AI agent
  AI_AGENT_GRANTABLE_ACTIONS = [
    "create_note",
    "update_note",
    "delete_note",
    "pin_note",
    "unpin_note",
    "confirm_read",
    "acknowledge_reminder",
    "add_comment",
    "create_decision",
    "update_decision_settings",
    "delete_decision",
    "pin_decision",
    "unpin_decision",
    "vote",
    "add_options",
    "close_decision",
    "add_statement",
    "create_commitment",
    "update_commitment_settings",
    "delete_commitment",
    "join_commitment",
    "pin_commitment",
    "unpin_commitment",
    "add_attachment",
    "remove_attachment",
    # Reminder actions
    "create_reminder_note",
    "cancel_reminder",
    # Table actions
    "create_table_note",
    "add_row",
    "update_row",
    "delete_row",
    "add_table_column",
    "remove_table_column",
    "query_rows",
    "summarize",
    "update_table_description",
    "batch_table_update",
    # Trustee grant actions
    "accept_trustee_grant",
    "decline_trustee_grant",
    "create_trustee_grant",
    "revoke_trustee_grant",
    # Representation sessions — agents can represent a user or a collective
    # on whose behalf they hold a trustee grant. Grantable (not always-allowed)
    # so the agent's owner can opt in per agent.
    "start_representation",
    "end_representation",
    # Content reporting
    "report_content",
  ].freeze

  # Check if a user has capability for an action
  #
  # @param user [User] The user attempting the action
  # @param action_name [String] The action to check
  # @return [Boolean] true if allowed, false if denied
  # Does this user's action set get filtered by CapabilityCheck?
  #
  # Returns true for users whose requests are gated by the allowed/blocked/
  # grantable lists below, false for users who bypass those checks. The
  # concrete policy is "ai_agents are restricted, everyone else isn't";
  # callers outside this module should go through this predicate rather
  # than hard-coding `user.ai_agent?` so the policy can widen later
  # without a shotgun edit.
  sig { params(user: User).returns(T::Boolean) }
  def self.restricted_user?(user)
    user.ai_agent?
  end

  sig { params(user: User, action_name: String).returns(T::Boolean) }
  def self.allowed?(user, action_name)
    # Non-restricted users (see `restricted_user?`) have no capability restrictions
    return true unless restricted_user?(user)

    # Infrastructure actions are always allowed
    return true if AI_AGENT_ALWAYS_ALLOWED.include?(action_name)

    # Blocked actions are never allowed
    return false if AI_AGENT_ALWAYS_BLOCKED.include?(action_name)

    # Everything past this point must be a grantable action to be considered.
    # Previously, an action that was neither ALLOWED nor BLOCKED nor GRANTABLE
    # would pass through and be allowed when `capabilities` was nil — a
    # fail-open default that silently permitted any newly-added action an
    # owner hadn't seen. Now: only actions in the explicit grantable list
    # can be granted, and only if the owner has granted them (or left the
    # configuration unset, which means "all grantable").
    return false unless AI_AGENT_GRANTABLE_ACTIONS.include?(action_name)

    capabilities = user.agent_configuration&.dig("capabilities")

    # No capabilities key (nil) = all grantable actions allowed (owner hasn't
    # narrowed them). Empty array = NONE. Non-empty = only those listed.
    return true if capabilities.nil?

    capabilities.include?(action_name)
  end

  # Get the list of allowed actions for a user
  #
  # @param user [User] The user to check
  # @return [Array<String>] List of allowed action names
  sig { params(user: User).returns(T::Array[String]) }
  def self.allowed_actions(user)
    return ActionsHelper::ACTION_DEFINITIONS.keys unless user.ai_agent?

    capabilities = user.agent_configuration&.dig("capabilities")

    grantable = if capabilities.nil?
                  # No capabilities key = all grantable actions allowed
                  AI_AGENT_GRANTABLE_ACTIONS
                else
                  # Empty array = nothing; non-empty = intersection with grantable
                  capabilities & AI_AGENT_GRANTABLE_ACTIONS
                end

    AI_AGENT_ALWAYS_ALLOWED + grantable
  end

  # Get the list of restricted actions for a user (for display)
  #
  # @param user [User] The user to check
  # @return [Array<String>, nil] List of restricted actions, or nil if no restrictions
  sig { params(user: User).returns(T.nilable(T::Array[String])) }
  def self.restricted_actions(user)
    return nil unless user.ai_agent?

    capabilities = user.agent_configuration&.dig("capabilities")
    # nil = no restrictions configured
    return nil if capabilities.nil?

    # Empty array = all grantable actions restricted
    # Non-empty array = those not in the list are restricted
    AI_AGENT_GRANTABLE_ACTIONS - capabilities
  end
end
