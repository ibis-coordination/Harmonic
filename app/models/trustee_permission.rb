# typed: false

class TrusteePermission < ActiveRecord::Base
  belongs_to :trustee_user, class_name: 'User'
  belongs_to :granting_user, class_name: 'User'
  belongs_to :trusted_user, class_name: 'User'

  before_validation :create_trustee_user!, on: :create

  validate :all_users_conform_to_expectations

  def display_name
    relationship_phrase.gsub('{trusted_user}', trusted_user.display_name).gsub('{granting_user}', granting_user.display_name)
  end

  def create_trustee_user!
    return if self.trustee_user
    self.trustee_user = User.create!(
      name: self.display_name,
      email: SecureRandom.uuid + '@not-a-real-email.com',
      user_type: 'trustee',
    )
  end

  def all_users_conform_to_expectations
    unless trustee_user.trustee?
      errors.add(:trustee_user, "must be a trustee user")
    end
    if granting_user == trusted_user
      errors.add(:trusted_user, "cannot be the same as the granting user")
    elsif granting_user == trustee_user
      errors.add(:trustee_user, "cannot be the same as the granting user")
    elsif trusted_user == trustee_user
      errors.add(:trustee_user, "cannot be the same as the trusted user")
    end
    if granting_user.trustee?
      # Currently this case only makes sense if the granting user that is of type 'trustee' is a studio trustee
      # and the trusted user is a member of the studio that the trustee user represents.
      # In this case, the trusted user is acting as a representative of the studio via the studio trustee.
      if !granting_user.studio_trustee?
        errors.add(:granting_user, "must be a studio trustee if the granting user is of type 'trustee'")
      elsif !granting_user.trustee_studio.users.include?(trusted_user)
        errors.add(:trusted_user, "must be a member of the studio that the granting user represents")
      end
    end
    if trusted_user.trustee?
      errors.add(:trusted_user, "cannot be a trustee user")
    end
  end

  def grant_permissions!(permissions)
    self.permissions = self.permissions.merge(permissions)
    save!
  end

  def revoke_permissions!(permissions)
    self.permissions = self.permissions.except(*permissions)
    save!
  end

end