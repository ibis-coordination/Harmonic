# typed: false

class OmniAuthIdentity < OmniAuth::Identity::Models::ActiveRecord
  auth_key :email
  validate :password_valid?

  # Password reset functionality
  def generate_reset_password_token!
    self.reset_password_token = SecureRandom.urlsafe_base64(32)
    self.reset_password_sent_at = Time.current
    save!
  end

  def reset_password_token_valid?
    reset_password_sent_at && reset_password_sent_at > 2.hours.ago
  end

  def clear_reset_password_token!
    self.reset_password_token = nil
    self.reset_password_sent_at = nil
    save!
  end

  def self.find_by_reset_password_token(token)
    find_by(reset_password_token: token)
  end

  def update_password!(new_password)
    self.password = new_password
    self.password_confirmation = new_password
    clear_reset_password_token!
    save!
  end

  def password_valid?
    # Passwords themselves are not persisted in the database, only the digest.
    # If password is nil and password_digest is not nil, that means the record has already been saved in the db.
    (self.password.nil? && !self.password_digest.nil?) || self.password.length >= 14
  end
end
