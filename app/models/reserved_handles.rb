# typed: strict

# Single source of truth for handles that are not ordinary, user-claimable
# handles. Two kinds live here:
#
#   * GROUP TAGS (@everyone, @admins) — collective-local aliases that a mention
#     expands to a *set* of users, by membership or role. They never name a real
#     user record, so no user (and no collective, whose identity user shares the
#     same tenant namespace) may claim them.
#   * AGENT HANDLES (@trio) — real user records that share one name across
#     collectives while each resolves collective-locally to the local instance.
#     Claimable only by a system agent whose system_role matches. This is also
#     the mechanism for the cross-collective agent-identity angle (@claude/@trio
#     → local instance).
#
# Before this registry the same facts were scattered across
# Collective::RESERVED_HANDLES, TenantUser::RESERVED_HANDLES, and
# MentionParser::TRIO_HANDLE, which had already drifted (a collective could be
# named "trio" even though the handle was reserved for users). Folding them into
# one place keeps reservation and collective-local resolution from diverging.
# (#449)
module ReservedHandles
  extend T::Sig

  # --- Group tags -----------------------------------------------------------
  EVERYONE = "everyone"
  ADMINS   = "admins"
  # @here (currently-active members) is intentionally deferred to a later pass.

  # Order is the fan-out order used when a mention names several tags.
  GROUP_TAGS = T.let([EVERYONE, ADMINS].freeze, T::Array[String])

  # --- Agent-identity handles ----------------------------------------------
  # handle => system_role required to claim it. Only the main collective's trio
  # actually holds the literal handle; per-collective trios carry hex-suffixed
  # handles and are reached through the collective-local resolution below.
  AGENT_ROLES = T.let({ "trio" => "trio" }.freeze, T::Hash[String, String])

  TRIO = "trio"

  # --- Collective-only reservations ----------------------------------------
  # Handles with no group/agent semantics that a collective still may not take.
  COLLECTIVE_ONLY = T.let(["main"].freeze, T::Array[String])

  # Handles a mention resolves *within the collective it was written in* rather
  # than through the tenant-wide handle index: group tags plus agent handles.
  # Resolving these locally is what stops a collective-local tag (or a shared
  # agent name) from fanning out to whoever happens to hold the literal handle
  # elsewhere in the tenant.
  COLLECTIVE_LOCAL = T.let((GROUP_TAGS + AGENT_ROLES.keys).freeze, T::Array[String])

  sig { params(handle: T.nilable(String)).returns(T::Boolean) }
  def self.group_tag?(handle)
    GROUP_TAGS.include?(handle.to_s.downcase)
  end

  sig { params(handle: T.nilable(String)).returns(T::Boolean) }
  def self.collective_local?(handle)
    COLLECTIVE_LOCAL.include?(handle.to_s.downcase)
  end

  # The system_role required to claim `handle` as a user, or nil when the handle
  # carries no role gate.
  sig { params(handle: T.nilable(String)).returns(T.nilable(String)) }
  def self.required_system_role(handle)
    AGENT_ROLES[handle.to_s.downcase]
  end

  # True when `handle` may not be claimed by a user with the given system_role.
  # Group tags are never a real user; an agent handle is claimable only by the
  # matching system_role (identity users, which carry no system_role, are thus
  # excluded from agent handles too).
  sig { params(handle: T.nilable(String), system_role: T.nilable(String)).returns(T::Boolean) }
  def self.forbidden_for_user?(handle, system_role: nil)
    return true if group_tag?(handle)

    required = required_system_role(handle)
    !required.nil? && system_role != required
  end

  # True when no collective may take `handle` as its handle. Group tags are
  # reserved so a collective (via its identity user) can't shadow the tag; the
  # "main" handle is reserved for the main collective. Agent handles are left
  # claimable as collective handles for backwards compatibility.
  sig { params(handle: T.nilable(String)).returns(T::Boolean) }
  def self.forbidden_for_collective?(handle)
    h = handle.to_s.downcase
    COLLECTIVE_ONLY.include?(h) || GROUP_TAGS.include?(h)
  end
end
