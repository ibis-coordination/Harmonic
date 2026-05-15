# typed: true

class MentionParser
  extend T::Sig

  MENTION_PATTERN = /@([a-zA-Z0-9_-]+)/
  TRIO_HANDLE = "trio"

  sig do
    params(
      text: T.nilable(String),
      tenant_id: T.nilable(String),
      collective: T.nilable(Collective),
    ).returns(T::Array[User])
  end
  def self.parse(text, tenant_id:, collective: nil)
    return [] if text.blank? || tenant_id.blank?

    handles = extract_handles(text)
    return [] if handles.empty?

    # Normal handle-based resolution. Trio's TenantUser handle is random hex,
    # so "trio" never matches via this index.
    users = TenantUser.where(tenant_id: tenant_id, handle: handles)
      .includes(:user)
      .map(&:user)

    # @trio is a magic handle that resolves to the current collective's trio
    # system agent. Only applies when a collective context is provided. The
    # `unless include?` guard catches the rare case where the text contains
    # both @trio and @<trio's-actual-random-hex-handle>; without it, trio
    # would appear twice in the result and downstream would send duplicate
    # notifications.
    if collective && handles.include?(TRIO_HANDLE)
      trio = collective.trio_user
      users << trio if trio && !users.include?(trio)
    end

    users
  end

  # Parse mentions and filter to valid notification recipients:
  # - Must be a member of the collective
  # - Must not be the excluded user (typically the actor)
  sig do
    params(
      text: T.nilable(String),
      tenant_id: T.nilable(String),
      collective: Collective,
      exclude_user: T.nilable(User),
    ).returns(T::Array[User])
  end
  def self.parse_for_notification(text, tenant_id:, collective:, exclude_user: nil)
    users = parse(text, tenant_id: tenant_id, collective: collective)
    users
      .reject { |u| exclude_user && u.id == exclude_user.id }
      .select { |u| collective.user_is_member?(u) }
  end

  sig { params(text: T.nilable(String)).returns(T::Array[String]) }
  def self.extract_handles(text)
    return [] if text.blank?

    text.scan(MENTION_PATTERN).flatten.uniq
  end
end
