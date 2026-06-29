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

    # When a collective is provided, "@trio" ALWAYS means this collective's
    # trio. The handle index would otherwise also resolve "@trio" to the
    # main collective's trio (which claims the literal handle "trio") even
    # when mentioned in some other collective, fanning out the mention to a
    # trio that isn't local to the conversation.
    index_handles = if collective
      handles - [TRIO_HANDLE]
    else
      handles
    end

    users = if index_handles.any?
      TenantUser.where(tenant_id: tenant_id, handle: index_handles)
        .includes(:user)
        .map(&:user)
    else
      []
    end

    if collective && handles.include?(TRIO_HANDLE)
      trio = collective.trio_user
      users << trio if trio
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

  # Resolve mentioned handles to profile paths so @mentions can be rendered
  # as links. Returns a hash of { handle => profile_path } containing only
  # the handles that resolve to a real user in the tenant. Resolution mirrors
  # .parse (including the collective-local @trio special case); handles that
  # don't resolve are omitted so callers can leave them as plain text.
  sig do
    params(
      text: T.nilable(String),
      tenant_id: T.nilable(String),
      collective: T.nilable(Collective),
    ).returns(T::Hash[String, String])
  end
  def self.resolve_paths(text, tenant_id:, collective: nil)
    return {} if text.blank? || tenant_id.blank?

    handles = extract_handles(text)
    return {} if handles.empty?

    # Same @trio handling as .parse: when a collective is provided, "@trio"
    # always means this collective's trio, resolved below rather than through
    # the tenant-wide handle index.
    index_handles = if collective
      handles - [TRIO_HANDLE]
    else
      handles
    end

    paths = {}

    if index_handles.any?
      TenantUser.where(tenant_id: tenant_id, handle: index_handles)
        .includes(:user)
        .each do |tenant_user|
          handle = tenant_user.handle
          path = tenant_user.user&.path
          paths[handle] = path if handle && path
        end
    end

    if collective && handles.include?(TRIO_HANDLE)
      trio_path = collective.trio_user&.path
      paths[TRIO_HANDLE] = trio_path if trio_path
    end

    paths
  end

  sig { params(text: T.nilable(String)).returns(T::Array[String]) }
  def self.extract_handles(text)
    return [] if text.blank?

    text.scan(MENTION_PATTERN).flatten.uniq
  end
end
