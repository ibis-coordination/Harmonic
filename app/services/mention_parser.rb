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

  sig { params(text: T.nilable(String)).returns(T::Array[String]) }
  def self.extract_handles(text)
    return [] if text.blank?

    text.scan(MENTION_PATTERN).flatten.uniq
  end
end
