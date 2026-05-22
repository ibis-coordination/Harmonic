# typed: true

class Invite < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :collective
  before_validation :set_collective_id
  belongs_to :created_by, class_name: 'User'
  belongs_to :invited_user, class_name: 'User', optional: true

  validate :collective_accepts_invites

  sig { void }
  def collective_accepts_invites
    c = collective
    return if c.nil?

    if c.is_main_collective?
      errors.add(:collective, "cannot be the main collective (members are added via tenant signup, not invite)")
    elsif c.private_workspace?
      errors.add(:collective, "cannot be a private workspace")
    elsif c.chat?
      errors.add(:collective, "cannot be a chat collective")
    elsif c.collective_type != "standard"
      errors.add(:collective, "must be a standard collective (got #{c.collective_type.inspect})")
    end
  end

  sig { void }
  def set_tenant_id
    self.tenant_id = T.must(Tenant.current_id) if tenant_id.nil?
  end

  sig { void }
  def set_collective_id
    self.collective_id = T.must(Collective.current_id) if collective_id.nil?
  end

  sig { returns(T.nilable(String)) }
  def shareable_link
    if invited_user
      nil # Invites for a specific user cannot be shared. The user must log in.
    else
      "#{T.must(collective).url}/join?code=#{code}"
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
    return false if user.collectives.include?(collective)
    return false if expired?
    return false unless collective_invitable?
    return true
  end

  # Whether the invite's collective is even a valid invite target.
  # Mirrors the collective_accepts_invites validation but is safe to call
  # on persisted records — defends against legacy invites that may exist
  # from before that validation was added.
  sig { returns(T::Boolean) }
  def collective_invitable?
    c = collective
    return false if c.nil?
    return false if c.is_main_collective?
    return false if c.private_workspace?
    return false if c.chat?
    c.collective_type == "standard"
  end

end
