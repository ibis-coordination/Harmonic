# typed: true

# ActionAuthorization provides declarative authorization for actions.
#
# This module is the single source of truth for determining whether a user
# can see or execute an action. Both the action listing (e.g., /actions page)
# and action execution should consult this module.
#
# Authorization types are defined in AUTHORIZATION_CHECKS and can be:
# - Symbols (e.g., :authenticated, :collective_member)
# - Arrays of symbols (OR logic - any authorization suffices)
# - Procs for custom logic
#
# Actions without explicit authorization are denied by default (fail-closed).
#
# @see ActionsHelper::ACTION_DEFINITIONS for action authorization assignments
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

      studio = context[:studio]
      # No studio context = permissive for listing (user might be admin of some studio)
      return true unless studio

      user.collective_members.find_by(collective_id: studio.id)&.is_admin? || false
    },

    # Role-based
    collective_member: lambda { |user, context|
      return false unless user

      studio = context[:studio]
      # No studio context = permissive for listing (user might be member of some studio)
      return true unless studio

      studio.user_is_member?(user)
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

      target = context[:target]
      # No target context = permissive for listing
      return true unless target

      user.can_represent?(target)
    },
  }.freeze, T::Hash[Symbol, T.proc.params(user: T.untyped, context: T::Hash[Symbol, T.untyped]).returns(T::Boolean)])

  # Check if a user is authorized to see/execute an action.
  #
  # @param action_name [String] The name of the action
  # @param user [User, nil] The user attempting the action
  # @param context [Hash] Additional context (studio, resource, target_user, target)
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

    true
  end

  # Check if a trustee user is authorized for this action.
  #
  # For user representation sessions: checks grant permissions.
  # For studio representation: collective trustees have full access.
  #
  # @param user [User, nil] The user attempting the action
  # @param action_name [String] The action to check
  # @param context [Hash] Additional context (studio, representation_session, etc.)
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

      # Check studio scope if context provided
      studio = context[:studio]
      return false if studio && !grant.allows_studio?(studio)

      # Check if grant allows this action
      return false unless grant.has_action_permission?(action_name)

      # CRITICAL: Grant inherits granting_user's restrictions
      return CapabilityCheck.allowed?(T.must(grant.granting_user), action_name)
    end

    # For studio representation: current_user is a collective_proxy user
    return true unless user&.collective_proxy?
    return true if user.proxy_collective.present?  # Collective proxies have full access

    # No other collective_proxy types should exist
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
