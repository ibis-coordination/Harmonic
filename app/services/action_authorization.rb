# typed: true

# ActionAuthorization provides declarative authorization for actions.
#
# This module is the single source of truth for determining whether a user
# can see or execute an action. The model is: set `authorization:` on the
# action's ACTION_DEFINITIONS entry; that rule is consulted for BOTH listings
# and executions.
#
# - Listings: MarkdownHelper#available_actions_for_current_route and the
#   controllers' actions_index_show endpoints call `authorized?` to decide
#   which actions to show, passing a context built by
#   MarkdownHelper#build_authorization_context.
# - Execution: ActionAuthorizationCheck (an ApplicationController before_action)
#   calls `authorized?` on every /actions/<name> POST before the controller's
#   execute_<name> method, denying with 403 when the rule rejects. Context comes
#   from the controller's `authorization_context` hook.
#
# The execute-time gate is ADDITIVE — controller authorize_* before_actions
# still run — so it can only ADD denials, never weaken an existing guard.
#
# Authorization types are defined in AUTHORIZATION_CHECKS and can be:
# - Symbols (e.g., :authenticated, :collective_member)
# - Arrays of symbols (OR logic - any authorization suffices)
# - Procs for custom logic
#
# Context keys: :collective, :resource, :target_user (the user the action is
# about — self checks), :represented_user (the resource the caller may represent —
# representative checks), :representation_session.
#
# Context-sensitive checks are PERMISSIVE when their key is absent (so listings
# show the action to any authenticated user); when the key IS present they do a
# strict check. At execute time the controller populates the relevant keys.
#
# Actions without explicit authorization are denied by default (fail-closed).
#
# @see ActionsHelper::ACTION_DEFINITIONS for action authorization assignments
# @see ActionAuthorizationCheck for the execute-time enforcement
module ActionAuthorization
  extend T::Sig

  # Authorization checks mapped by symbol.
  # Each check is a Proc that takes (user, context) and returns a boolean.
  #
  # Admin levels are independent flags - a user can have any combination.
  # There is no inheritance between admin levels.
  #
  # Context-sensitive checks (collective_member, collective_admin, resource_owner, self, representative)
  # are PERMISSIVE when no context is provided (for /actions listing) - they allow any authenticated
  # user to see the action. When context IS provided (for execution), they do strict checks.
  AUTHORIZATION_CHECKS = T.let({
    # Public/authenticated
    public: ->(_user, _context) { true },
    authenticated: ->(user, _context) { user.present? },

    # Admin levels (independent, not hierarchical)
    system_admin: ->(user, _context) { user&.sys_admin? || false },
    app_admin: ->(user, _context) { user&.app_admin? || false },
    tenant_admin: ->(user, _context) { user&.tenant_user&.is_admin? || false },
    collective_admin: lambda { |user, context|
      return false unless user

      collective = context[:collective]
      # No collective context = permissive for listing (user might be admin of some collective)
      return true unless collective
      # The collective's own identity user acts as an admin of its own collective.
      return true if collective.identity_user?(user)

      user.collective_members.find_by(collective_id: collective.id)&.is_admin? || false
    },

    # Role-based
    collective_member: lambda { |user, context|
      return false unless user

      collective = context[:collective]
      # No collective context = permissive for listing (user might be member of some collective)
      return true unless collective
      # The collective's own identity user acts as a member of its own collective.
      return true if collective.identity_user?(user)
      # A collective identity is a real CollectiveMember of the tenant's main
      # collective (created by Collective#create_identity_user! and backfilled for
      # existing identities in #477), so authoring at the public root (/note) over
      # markdown/MCP now passes on the general membership path below — no special
      # case needed. This was previously a carve-out (#469) that #477 made vestigial.
      collective.user_is_member?(user)
    },
    resource_owner: lambda { |user, context|
      return false unless user

      resource = context[:resource]
      # No resource context = permissive for listing (user might own some resource)
      return true unless resource

      resource.respond_to?(:created_by_id) && resource.created_by_id == user.id
    },
    self: lambda { |user, context|
      return false unless user

      target_user = context[:target_user]
      # No target_user context = permissive for listing
      return true unless target_user

      target_user.id == user.id
    },
    self_ai_agent: lambda { |user, context|
      return false unless user&.ai_agent?

      target_user = context[:target_user]
      # No target_user context = permissive for listing (shows action to AI agents)
      return true unless target_user

      target_user.id == user.id
    },
    representative: lambda { |user, context|
      return false unless user

      represented_user = context[:represented_user]
      # No represented_user context = permissive for listing
      return true unless represented_user

      user.can_represent?(represented_user)
    },
  }.freeze, T::Hash[Symbol, T.proc.params(user: T.untyped, context: T::Hash[Symbol, T.untyped]).returns(T::Boolean)])

  # Check if a user is authorized to see/execute an action.
  #
  # @param action_name [String] The name of the action
  # @param user [User, nil] The user attempting the action
  # @param context [Hash] Additional context (collective, resource, target_user, represented_user)
  # @return [Boolean] true if authorized, false otherwise
  sig do
    params(
      action_name: String,
      user: T.untyped,
      context: T::Hash[Symbol, T.untyped]
    ).returns(T::Boolean)
  end
  def self.authorized?(action_name, user, context = {})
    action = ActionsHelper::ACTION_DEFINITIONS[action_name]
    return false unless action # Unknown action = denied

    auth = action[:authorization]
    return false if auth.nil? # No auth specified = denied (fail closed)

    # Check base authorization first
    return false unless check_authorization(auth, user, context)

    # Then check capability restrictions for AI agents
    return false unless CapabilityCheck.allowed?(user, action_name)

    # Then check trustee grant restrictions
    return false unless trustee_authorized?(user, action_name, context)

    # Then check user block restrictions
    return false if blocked_from_action?(user, action_name, context)

    true
  end

  # Actions that require interaction with a resource author and should
  # be denied when a block exists between the user and the author.
  BLOCK_CHECKED_ACTIONS = T.let(%w[
    confirm_read acknowledge_reminder add_comment
    vote add_options
    join_commitment
  ].freeze, T::Array[String])

  # Check if a user is blocked from performing an action on a resource.
  # Permissive when no resource is in context (for action listings without a specific resource).
  sig do
    params(
      user: T.untyped,
      action_name: String,
      context: T::Hash[Symbol, T.untyped]
    ).returns(T::Boolean)
  end
  def self.blocked_from_action?(user, action_name, context)
    return false unless BLOCK_CHECKED_ACTIONS.include?(action_name)
    return false unless user

    resource = context[:resource]
    return false unless resource
    return false unless resource.respond_to?(:created_by) && resource.created_by

    UserBlock.between?(user, resource.created_by)
  end

  # Check if a trustee user is authorized for this action.
  #
  # For user representation sessions: checks grant permissions.
  # For collective representation: collective trustees have full access.
  #
  # @param user [User, nil] The user attempting the action
  # @param action_name [String] The action to check
  # @param context [Hash] Additional context (collective, representation_session, etc.)
  # @return [Boolean] true if authorized, false otherwise
  sig do
    params(
      user: T.untyped,
      action_name: String,
      context: T::Hash[Symbol, T.untyped]
    ).returns(T::Boolean)
  end
  def self.trustee_authorized?(user, action_name, context)
    # Check if there's an active user representation session
    # For user representation, current_user is the granting_user (not a trustee type),
    # so we need to check grant permissions via the session
    rep_session = context[:representation_session]
    if rep_session&.user_representation?
      grant = rep_session.trustee_grant
      return false unless grant&.active?

      # Check collective scope if context provided
      collective = context[:collective]
      return false if collective && !grant.allows_collective?(collective)

      # Check if grant allows this action
      return false unless grant.has_action_permission?(action_name)

      # CRITICAL: Grant inherits granting_user's restrictions
      return CapabilityCheck.allowed?(T.must(grant.granting_user), action_name)
    end

    # For collective representation: current_user is a collective_identity user
    return true unless user&.collective_identity?
    return true if user.identity_collective.present?  # Collective identity users have full access

    # No other collective_identity types should exist
    false
  end

  # Check authorization against a specific authorization rule.
  #
  # @param auth [Symbol, Proc, Array] The authorization rule
  # @param user [User, nil] The user attempting the action
  # @param context [Hash] Additional context
  # @return [Boolean] true if authorized, false otherwise
  sig do
    params(
      auth: T.any(Symbol, T.proc.params(user: T.untyped, context: T::Hash[Symbol, T.untyped]).returns(T::Boolean), T::Array[T.untyped]),
      user: T.untyped,
      context: T::Hash[Symbol, T.untyped]
    ).returns(T::Boolean)
  end
  def self.check_authorization(auth, user, context)
    case auth
    when Symbol
      check = AUTHORIZATION_CHECKS[auth]
      return false unless check

      check.call(user, context)
    when Proc
      auth.call(user, context)
    when Array
      # Array means ANY of these authorizations suffice (OR logic)
      auth.any? { |a| check_authorization(a, user, context) }
    end
  end
end
