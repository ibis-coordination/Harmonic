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
module CapabilityCheck # rubocop:disable Metrics/ModuleLength
  extend T::Sig

  # Actions that AI agents can always perform (infrastructure)
  # These are essential for navigation and basic app operation
  AI_AGENT_ALWAYS_ALLOWED = [
    "send_heartbeat",
    "dismiss",
    "dismiss_all",
    "dismiss_for_collective",
    "dismiss_for_chat",
    "mark_read",
    "mark_all_read",
    "mark_read_for_collective",
    "update_scratchpad",
  ].freeze

  # Actions that AI agents can never perform
  # These are sensitive operations that should only be done by humans
  AI_AGENT_ALWAYS_BLOCKED = [
    "create_collective",
    "join_collective",
    "update_collective_settings",
    # Funding-pool actions move real money: enrollment is a member's personal
    # consent to be drawn on, and attach/detach direct the pool's spending.
    # Humans only — the enrollment model additionally refuses non-human users.
    "enroll_in_funding_pool",
    "withdraw_from_funding_pool",
    "attach_funded_agent",
    "detach_funded_agent",
    "set_pool_ceiling",
    # Enabling Trio commits the collective to paid-feature spend and adds
    # members; like the other collective-configuration actions, humans only.
    "set_trio_enabled",
    "create_ai_agent",
    "add_ai_agent_to_collective",
    "create_api_token",
    "update_profile",
    # Notification preferences govern which events reach the agent — its
    # effective wake/trigger surface. Same reasoning as automation rules below:
    # agents should not be self-modifying what notifies them. The owner/trustee
    # configures this through the settings UI (gated by can_edit?, not this
    # list), so blocking the agent-as-actor here doesn't affect that path.
    "update_notification_preferences",
    "create_webhook",
    "update_webhook",
    "delete_webhook",
    "test_webhook",
    "suspend_user",
    "unsuspend_user",
    "toggle_billing_exempt",
    "update_tenant_settings",
    "create_tenant",
    "retry_sidekiq_job",
    # Automation rule management is owner-scoped; agents should not be
    # self-modifying their trigger graph. (HUMAN_SELF_OR_REPRESENTATIVE already
    # blocks these at the action-authorization layer, but listing them here
    # makes the policy explicit and test-auditable.)
    "create_automation_rule",
    "update_automation_rule",
    "delete_automation_rule",
    "toggle_automation_rule",
    # Bridge setup mints an MCP token + binds a notification webhook URL.
    # Same operator-only category as create_api_token. HUMAN_SELF_OR_REPRESENTATIVE
    # already enforces this at the action layer; listing here makes the policy
    # explicit and test-auditable.
    "connect_harmonic_bridge",
    "cancel_harmonic_bridge_setup",
  ].freeze

  # Capabilities an AI agent needs in its overall configuration before it
  # can engage with a trustee authorization at all — accept it, start a
  # rep session under it, end the session. Independent of the per-grant
  # `TrusteeGrant::GRANTABLE_ACTIONS` checklist, since these are
  # rep-lifecycle actions not in-session permissions.
  REP_LIFECYCLE_ACTIONS = [
    "accept_trustee_authorization",
    "start_representation",
    "end_representation",
  ].freeze

  # Returns the rep-lifecycle actions that the given user is missing from
  # their agent capability configuration. Always empty for non-agents, and
  # empty when `agent_configuration["capabilities"]` is nil (the "all
  # grantable" default).
  sig { params(user: User).returns(T::Array[String]) }
  def self.missing_rep_lifecycle_capabilities(user)
    return [] unless user.ai_agent?

    capabilities = user.agent_configuration&.dig("capabilities")
    return [] if capabilities.nil?

    REP_LIFECYCLE_ACTIONS - capabilities
  end

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
    "add_summary",
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
    # Collective member management — an elevation-of-privilege surface (grants/
    # revokes admin and other roles, removes members). Grantable, not blocked:
    # an agent can only act here when it ALSO passes the action's
    # `:collective_admin` authorization, i.e. a human has deliberately made it a
    # collective admin. So this is a two-key control — owner-granted capability
    # AND collective-admin standing — not a self-elevation path.
    "update_member_roles",
    "remove_member",
    # Trustee grant actions
    "accept_trustee_authorization",
    "decline_trustee_authorization",
    "create_trustee_authorization",
    "revoke_trustee_authorization",
    # Representation sessions — agents can represent a user or a collective
    # on whose behalf they hold a trustee grant. Grantable (not always-allowed)
    # so the agent's owner can opt in per agent.
    "start_representation",
    "end_representation",
    # Content reporting
    "report_content",
    # Chat
    "send_message",
    # UserList — "tune in" gesture
    "tune_in",
    "tune_out",
    # UserList — custom list CRUD
    "create_user_list",
    "update_user_list",
    "delete_user_list",
    # UserList — member management on specific lists
    "add_member_to_list",
    "remove_member_from_list",
    "join_list",
  ].freeze

  # Grouped presentation of AI_AGENT_GRANTABLE_ACTIONS for the agent-creation
  # and agent-settings forms. Every grantable action belongs to exactly one
  # group. Groups with `default_unchecked: true` are rendered unchecked when
  # an agent has no capabilities configured yet (sensitive / destructive
  # actions the owner should opt into deliberately). The CapabilityCheck test
  # suite enforces the groups stay in sync with AI_AGENT_GRANTABLE_ACTIONS —
  # adding or removing a grantable action will fail tests until the groups
  # are updated.
  AI_AGENT_GRANTABLE_GROUPS = [
    {
      name: "Notes",
      description: "Create, edit, and pin notes.",
      actions: ["create_note", "update_note", "pin_note", "unpin_note"],
    },
    {
      name: "Notes — destructive",
      description: "Permanently delete notes.",
      actions: ["delete_note"],
      default_unchecked: true,
    },
    {
      name: "Reading & reminders",
      description: "Mark notes and reminders as read; create and cancel reminder notes.",
      actions: ["confirm_read", "acknowledge_reminder", "create_reminder_note", "cancel_reminder"],
    },
    {
      name: "Comments",
      description: "Post comments on notes, decisions, and commitments.",
      actions: ["add_comment"],
    },
    {
      name: "Summaries",
      description: "Write or update the summary of a note, decision, or commitment.",
      actions: ["add_summary"],
    },
    {
      name: "Decisions",
      description: "Create decisions, vote, add options and statements, close decisions, edit settings.",
      actions: [
        "create_decision", "update_decision_settings",
        "pin_decision", "unpin_decision", "vote", "add_options",
        "close_decision", "add_statement",
      ],
    },
    {
      name: "Decisions — destructive",
      description: "Permanently delete decisions.",
      actions: ["delete_decision"],
      default_unchecked: true,
    },
    {
      name: "Commitments",
      description: "Create and join commitments; pin and edit settings.",
      actions: [
        "create_commitment", "update_commitment_settings",
        "join_commitment", "pin_commitment", "unpin_commitment",
      ],
    },
    {
      name: "Commitments — destructive",
      description: "Permanently delete commitments.",
      actions: ["delete_commitment"],
      default_unchecked: true,
    },
    {
      name: "Tables",
      description: "Create table notes, add and edit rows and columns, query and summarize data.",
      actions: [
        "create_table_note", "add_row", "update_row", "add_table_column",
        "query_rows", "summarize", "update_table_description", "batch_table_update",
      ],
    },
    {
      name: "Tables — destructive",
      description: "Delete rows and remove columns.",
      actions: ["delete_row", "remove_table_column"],
      default_unchecked: true,
    },
    {
      name: "Attachments",
      description: "Upload and remove file attachments.",
      actions: ["add_attachment", "remove_attachment"],
      default_unchecked: true,
    },
    {
      name: "Chat",
      description: "Send messages in chat conversations.",
      actions: ["send_message"],
    },
    {
      name: "Lists",
      description: "Tune in to people and lists; create and manage custom lists.",
      actions: [
        "tune_in", "tune_out", "create_user_list", "update_user_list",
        "add_member_to_list", "join_list",
      ],
    },
    {
      name: "Lists — destructive",
      description: "Delete custom lists and remove other members from them.",
      actions: ["delete_user_list", "remove_member_from_list"],
      default_unchecked: true,
    },
    {
      name: "Trustee authorization responses",
      description: "Accept or decline trustee grants offered to this agent.",
      actions: ["accept_trustee_authorization", "decline_trustee_authorization"],
    },
    {
      name: "Trustee authorization admin",
      description: "Grant trustee authority to others, and revoke grants.",
      actions: ["create_trustee_authorization", "revoke_trustee_authorization"],
      default_unchecked: true,
    },
    {
      name: "Representation",
      description: "Start and end sessions where the agent acts on behalf of a user or collective via a trustee grant.",
      actions: ["start_representation", "end_representation"],
    },
    {
      name: "Content reporting",
      description: "Report notes, decisions, or commitments for review.",
      actions: ["report_content"],
    },
    {
      name: "Member management",
      description: "Grant and revoke member roles (admin, representative, summarizer) and remove members. " \
                   "Only takes effect when the agent is itself an admin of the collective.",
      actions: ["update_member_roles", "remove_member"],
      default_unchecked: true,
    },
  ].freeze

  # Groups whose actions gate the representation *relationship* rather than
  # what a trustee does in-session, so they're excluded from the trustee
  # form (see TRUSTEE_GRANTABLE_GROUPS).
  TRUSTEE_EXCLUDED_GROUP_NAMES = [
    "Trustee authorization responses",
    "Trustee authorization admin",
    "Representation",
    # Member management governs the collective's own authority structure, not
    # in-session content work. It's exposed as an agent capability (an owner
    # arming their own agent that they've made a collective admin), but kept off
    # the per-grant trustee checklist for now — delegating collective-governance
    # power through a personal trustee grant is a separate policy decision.
    "Member management",
  ].freeze

  # Capability groups shown on the trustee-authorization form (issue #260),
  # mirroring the agent capability form so the two surfaces stay in sync.
  # Starts from AI_AGENT_GRANTABLE_GROUPS (the full content set), then:
  #   - drops the rep-lifecycle / trustee-admin groups above. A trustee
  #     grant's permission map governs what the trustee may do *while acting
  #     on the grantor's behalf*; accepting grants, representing, and granting
  #     trusteeship govern the relationship itself, not in-session behavior, so
  #     listing them in a per-grant checklist is a category error.
  #   - adds "Collective presence" (send_heartbeat). Trustees could already be
  #     granted this; agents instead get it as an always-allowed infrastructure
  #     action, so it isn't in the agent grantable groups.
  TRUSTEE_GRANTABLE_GROUPS = (
    AI_AGENT_GRANTABLE_GROUPS.reject { |group| TRUSTEE_EXCLUDED_GROUP_NAMES.include?(group[:name]) } +
    [
      {
        name: "Collective presence",
        description: "Send a heartbeat to mark presence in a collective's cycle.",
        actions: ["send_heartbeat"],
      },
    ]
  ).freeze

  # Flat list of trustee-grantable action names, derived from the groups so the
  # form and the model's permission allowlist (TrusteeGrant::GRANTABLE_ACTIONS)
  # cannot drift apart.
  TRUSTEE_GRANTABLE_ACTIONS = TRUSTEE_GRANTABLE_GROUPS.flat_map { |group| group[:actions] }.freeze

  # Public-write guardrail — the sibling restriction to capabilities.
  #
  # Capabilities restrict *which actions* an agent may take; this restricts
  # whether the agent may *write to the public visibility tier* (the
  # tenant-wide main collective). Same storage (a key on
  # `User#agent_configuration`), same restricted_user? gate, same fail-closed
  # request enforcement (see ActionContextValidation), same settings UI.
  #
  # Every agent action resolves to a visibility tier via
  # `Mcp::AudienceResolver.resolve`. We only gate the `public` tier:
  #
  #   private — the agent's own workspace; always allowed.
  #   shared  — collective spaces; always allowed. Already scoped by collective
  #             membership (don't add the agent to a collective you don't want
  #             it writing to), so a separate toggle would be redundant.
  #   public  — the tenant-wide main collective. DISABLED by default, owner can
  #             enable via `allow_public_writes`. Off by default because an
  #             agent with read-only access to a non-public collective could
  #             otherwise leak that content into the public space.
  #
  # This is intentionally a single boolean rather than a per-tier allowlist:
  # private and shared need no toggle, so the only meaningful control is
  # whether public writes are permitted.

  # May this agent write to the public visibility tier?
  #
  # @param user [User] The user attempting the action
  # @return [Boolean] true if allowed, false if denied
  sig { params(user: User).returns(T::Boolean) }
  def self.public_writes_allowed?(user)
    # Non-restricted users (see `restricted_user?`) have no write restrictions.
    return true unless restricted_user?(user)

    # Off by default: only the boolean `true` enables it. The write paths
    # (AiAgentsController#update_settings, ApiHelper) cast input to a real
    # boolean, so `true` is the only value we ever expect to store. We compare
    # against it explicitly rather than coercing on read: an unexpected value
    # (a string left by a hand-edited config or seed, anything other than
    # `true`) should keep the gate closed, not be interpreted. Fail closed.
    user.agent_configuration&.dig("allow_public_writes") == true
  end

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
end
