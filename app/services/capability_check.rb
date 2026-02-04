# typed: true

# CapabilityCheck provides capability-based authorization for subagent actions.
#
# This module determines which actions a subagent can perform based on:
# 1. Always-allowed infrastructure actions (essential for navigation)
# 2. Grantable actions (configurable by the agent owner)
# 3. Always-blocked actions (never allowed for subagents)
#
# If capabilities key is absent (nil), all grantable actions are allowed (backwards compatible default).
# If capabilities is an empty array, NO grantable actions are allowed.
# If capabilities has items, only those listed grantable actions are permitted.
#
# @see ActionAuthorization for base authorization checks
module CapabilityCheck
  extend T::Sig

  # Actions that subagents can always perform (infrastructure)
  # These are essential for navigation and basic app operation
  SUBAGENT_ALWAYS_ALLOWED = [
    "send_heartbeat",
    "mark_read",
    "dismiss",
    "mark_all_read",
    "search",
    "update_scratchpad",
  ].freeze

  # Actions that subagents can never perform
  # These are sensitive operations that should only be done by humans
  SUBAGENT_ALWAYS_BLOCKED = [
    "create_studio",
    "join_studio",
    "update_studio_settings",
    "create_subagent",
    "add_subagent_to_studio",
    "remove_subagent_from_studio",
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
  ].freeze

  # Actions that can be granted/denied via configuration
  # The owner can allow or deny these actions for their subagent
  SUBAGENT_GRANTABLE_ACTIONS = [
    "create_note",
    "update_note",
    "pin_note",
    "unpin_note",
    "confirm_read",
    "add_comment",
    "create_decision",
    "update_decision_settings",
    "pin_decision",
    "unpin_decision",
    "vote",
    "add_options",
    "create_commitment",
    "update_commitment_settings",
    "join_commitment",
    "pin_commitment",
    "unpin_commitment",
    "add_attachment",
    "remove_attachment",
    "create_reminder",
    "delete_reminder",
  ].freeze

  # Check if a user has capability for an action
  #
  # @param user [User] The user attempting the action
  # @param action_name [String] The action to check
  # @return [Boolean] true if allowed, false if denied
  sig { params(user: User, action_name: String).returns(T::Boolean) }
  def self.allowed?(user, action_name)
    # Non-subagents have no capability restrictions
    return true unless user.subagent?

    # Infrastructure actions are always allowed
    return true if SUBAGENT_ALWAYS_ALLOWED.include?(action_name)

    # Blocked actions are never allowed
    return false if SUBAGENT_ALWAYS_BLOCKED.include?(action_name)

    # Check configured capabilities for grantable actions
    capabilities = user.agent_configuration&.dig("capabilities")

    # No capabilities key (nil) = all grantable actions allowed (backwards compatible default)
    return true if capabilities.nil?

    # Empty array = NO grantable actions allowed
    # Non-empty array = only those actions allowed
    capabilities.include?(action_name)
  end

  # Get the list of allowed actions for a user
  #
  # @param user [User] The user to check
  # @return [Array<String>] List of allowed action names
  sig { params(user: User).returns(T::Array[String]) }
  def self.allowed_actions(user)
    return ActionsHelper::ACTION_DEFINITIONS.keys unless user.subagent?

    capabilities = user.agent_configuration&.dig("capabilities")

    grantable = if capabilities.nil?
                  # No capabilities key = all grantable actions allowed
                  SUBAGENT_GRANTABLE_ACTIONS
                else
                  # Empty array = nothing; non-empty = intersection with grantable
                  capabilities & SUBAGENT_GRANTABLE_ACTIONS
                end

    SUBAGENT_ALWAYS_ALLOWED + grantable
  end

  # Get the list of restricted actions for a user (for display)
  #
  # @param user [User] The user to check
  # @return [Array<String>, nil] List of restricted actions, or nil if no restrictions
  sig { params(user: User).returns(T.nilable(T::Array[String])) }
  def self.restricted_actions(user)
    return nil unless user.subagent?

    capabilities = user.agent_configuration&.dig("capabilities")
    # nil = no restrictions configured
    return nil if capabilities.nil?

    # Empty array = all grantable actions restricted
    # Non-empty array = those not in the list are restricted
    SUBAGENT_GRANTABLE_ACTIONS - capabilities
  end
end
