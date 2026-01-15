# typed: true

class TrusteePermission < ActiveRecord::Base
  extend T::Sig

  belongs_to :trustee_user, class_name: 'User'
  belongs_to :granting_user, class_name: 'User'
  belongs_to :trusted_user, class_name: 'User'

  before_validation :create_trustee_user!, on: :create

  validate :all_users_conform_to_expectations

  sig { returns(String) }
  def display_name
    T.must(relationship_phrase).gsub('{trusted_user}', T.must(T.must(trusted_user).display_name)).gsub('{granting_user}', T.must(T.must(granting_user).display_name))
  end

  sig { void }
  def create_trustee_user!
    return if self.trustee_user
    self.trustee_user = User.create!(
      name: self.display_name,
      email: SecureRandom.uuid + '@not-a-real-email.com',
      user_type: 'trustee',
    )
  end

  sig { void }
  def all_users_conform_to_expectations
    unless T.must(trustee_user).trustee?
      errors.add(:trustee_user, "must be a trustee user")
    end
    if granting_user == trusted_user
      errors.add(:trusted_user, "cannot be the same as the granting user")
    elsif granting_user == trustee_user
      errors.add(:trustee_user, "cannot be the same as the granting user")
    elsif trusted_user == trustee_user
      errors.add(:trustee_user, "cannot be the same as the trusted user")
    end
    if T.must(granting_user).trustee?
      # Currently this case only makes sense if the granting user that is of type 'trustee' is a superagent trustee
      # and the trusted user is a member of the superagent that the trustee user represents.
      # In this case, the trusted user is acting as a representative of the superagent via the superagent trustee.
      if !T.must(granting_user).superagent_trustee?
        errors.add(:granting_user, "must be a superagent trustee if the granting user is of type 'trustee'")
      elsif !T.must(granting_user).trustee_superagent&.users&.include?(trusted_user)
        errors.add(:trusted_user, "must be a member of the superagent that the granting user represents")
      end
    end
    if T.must(trusted_user).trustee?
      errors.add(:trusted_user, "cannot be a trustee user")
    end
  end

  sig { params(permissions: T::Hash[String, T.untyped]).void }
  def grant_permissions!(permissions)
    self.permissions = T.must(self.permissions).merge(permissions)
    save!
  end

  sig { params(permissions: T::Array[String]).void }
  def revoke_permissions!(permissions)
    self.permissions = T.must(self.permissions).except(*permissions)
    save!
  end

end