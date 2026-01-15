# typed: true

class Invite < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :superagent
  before_validation :set_superagent_id
  belongs_to :created_by, class_name: 'User'
  belongs_to :invited_user, class_name: 'User', optional: true

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(Tenant.current_id) if tenant_id.nil?
  end

  sig { void }
  def set_superagent_id
    self.superagent_id = T.must(Superagent.current_id) if superagent_id.nil?
  end

  sig { returns(T.nilable(String)) }
  def shareable_link
    if invited_user
      nil # Invites for a specific user cannot be shared. The user must log in.
    else
      "#{T.must(superagent).url}/join?code=#{code}"
    end
  end

  sig { returns(T::Boolean) }
  def expired?
    return false if expires_at.nil?
    T.must(expires_at) < Time.now
  end

  sig { params(user: User).returns(T::Boolean) }
  def is_acceptable_by_user?(user)
    return false if invited_user && invited_user != user
    return false if user.superagents.include?(superagent)
    return false if expired?
    return true
  end

end
