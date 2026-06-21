# typed: true

# Request-scoped context for representation. Wraps the `Current` attribute
# so callers and readers go through a domain API rather than a raw
# CurrentAttributes accessor — mirrors the `AutomationContext` pattern.
#
# Set by `ApplicationController` alongside `@current_representation_session`
# during request resolution. Read by model hooks that need to attribute
# auto-generated side effects (like read confirmations) to the user who
# actually performed the action — the representative — rather than the
# represented user.
#
# Example:
#   # Inside the after_create hook:
#   reader = RepresentationContext.current_representative_user || created_by
module RepresentationContext
  extend T::Sig

  sig { returns(T.nilable(User)) }
  def self.current_representative_user
    Current.acting_representative_user
  end

  sig { params(user: T.nilable(User)).void }
  def self.set!(user)
    Current.acting_representative_user = user
  end

  sig { void }
  def self.clear!
    Current.acting_representative_user = nil
  end
end
