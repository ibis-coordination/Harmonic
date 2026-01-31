# typed: true

# ActionAuthorization provides declarative authorization for actions.
#
# This module is the single source of truth for determining whether a user
# can see or execute an action. Both the action listing (e.g., /actions page)
# and action execution should consult this module.
#
# Authorization types are defined in AUTHORIZATION_CHECKS and can be:
# - Symbols (e.g., :authenticated, :superagent_member)
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
  # Context-sensitive checks (superagent_member, superagent_admin, resource_owner, self, representative)
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
    superagent_admin: lambda { |user, context|
      return false unless user

      studio = context[:studio]
      # No studio context = permissive for listing (user might be admin of some studio)
      return true unless studio

      user.superagent_members.find_by(superagent_id: studio.id)&.is_admin? || false
    },

    # Role-based
    superagent_member: lambda { |user, context|
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

    check_authorization(auth, user, context)
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
