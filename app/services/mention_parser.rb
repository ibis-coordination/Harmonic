# typed: true

class MentionParser
  extend T::Sig

  MENTION_PATTERN = /@([a-zA-Z0-9_-]+)/

  sig { params(text: T.nilable(String), tenant_id: T.nilable(String)).returns(T::Array[User]) }
  def self.parse(text, tenant_id:)
    return [] if text.blank? || tenant_id.blank?

    handles = extract_handles(text)
    return [] if handles.empty?

    TenantUser.where(tenant_id: tenant_id, handle: handles)
      .includes(:user)
      .map(&:user)
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
    users = parse(text, tenant_id: tenant_id)
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
