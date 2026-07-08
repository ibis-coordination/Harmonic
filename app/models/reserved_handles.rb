# typed: strict

# Single source of truth for handles that are not ordinary, user-claimable
# handles. Two kinds live here:
#
#   * GROUP TAGS (@everyone, @admins, @representatives, @summarizers, …) —
#     collective-local aliases that a mention expands to a *set* of users, by
#     membership or role. They never name a real user record, so no user (and
#     no collective, whose identity user shares the same tenant namespace) may
#     claim them.
#   * AGENT HANDLES (@trio) — real user records that share one name across
#     collectives while each resolves collective-locally to the local instance.
#     Claimable only by a system agent whose system_role matches. This is also
#     the mechanism for the cross-collective agent-identity angle (@claude/@trio
#     → local instance).
#
# The role group tags are DERIVED from the collective role list
# (CollectiveMember.valid_roles) rather than hardcoded, so adding a role — or,
# later, a per-collective custom role — automatically reserves and resolves its
# @<role>s tag with no change here. (#453 feedback)
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
  # @here (currently-active members) is intentionally deferred to a later pass.

  # Each collective role maps to its pluralized tag (admin → @admins,
  # representative → @representatives, summarizer → @summarizers). Keyed by tag
  # so resolution and reservation can look up the role a tag expands to. Derived
  # from the role list, so it tracks new/custom roles automatically.
  sig { returns(T::Hash[String, String]) }
  def self.role_tags
    T.unsafe(CollectiveMember).valid_roles.index_by { |role| role.pluralize }
  end

  # @everyone plus every role tag: the handles a mention expands to a *set* of
  # users. No user or collective may claim any of them.
  sig { returns(T::Array[String]) }
  def self.group_tags
    [EVERYONE] + role_tags.keys
  end

  # --- Agent-identity handles ----------------------------------------------
  # handle => system_role required to claim it. Only the main collective's trio
  # actually holds the literal handle; per-collective trios carry hex-suffixed
  # handles and are reached through the collective-local resolution below.
  AGENT_ROLES = T.let({ "trio" => "trio" }.freeze, T::Hash[String, String])

  TRIO = "trio"

  # --- Collective-only reservations ----------------------------------------
  # Handles with no group/agent semantics that a collective still may not take.
  COLLECTIVE_ONLY = T.let(["main"].freeze, T::Array[String])

  sig { params(handle: T.nilable(String)).returns(T::Boolean) }
  def self.group_tag?(handle)
    group_tags.include?(handle.to_s.downcase)
  end

  # True when a mention resolves `handle` *within the collective it was written
  # in* rather than through the tenant-wide handle index: group tags plus agent
  # handles. Resolving these locally is what stops a collective-local tag (or a
  # shared agent name) from fanning out to whoever happens to hold the literal
  # handle elsewhere in the tenant.
  sig { params(handle: T.nilable(String)).returns(T::Boolean) }
  def self.collective_local?(handle)
    h = handle.to_s.downcase
    group_tag?(h) || AGENT_ROLES.key?(h)
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
    COLLECTIVE_ONLY.include?(h) || group_tag?(h)
  end
end
