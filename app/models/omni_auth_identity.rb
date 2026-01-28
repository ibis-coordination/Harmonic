# typed: true

class OmniAuthIdentity < OmniAuth::Identity::Models::ActiveRecord
  extend T::Sig

  # Load common passwords list for validation
  COMMON_PASSWORDS_FILE = Rails.root.join("config", "common_passwords.txt")
  COMMON_PASSWORDS = T.let(
    if File.exist?(COMMON_PASSWORDS_FILE)
      Set.new(
        File.readlines(COMMON_PASSWORDS_FILE)
            .map(&:strip)
            .reject { |line| line.empty? || line.start_with?("#") }
            .map(&:downcase)
      )
    else
      Set.new
    end,
    T::Set[String]
  )

  auth_key :email
  validate :password_valid?
  validate :password_not_common

  # Password reset functionality
  # Tokens are stored as SHA256 hashes for security - if the database is compromised,
  # attackers cannot use the hashed tokens to reset passwords.
  sig { returns(String) }
  def generate_reset_password_token!
    raw_token = SecureRandom.urlsafe_base64(32)
    self.reset_password_token = Digest::SHA256.hexdigest(raw_token)
    self.reset_password_sent_at = T.cast(Time.current, ActiveSupport::TimeWithZone)
    save!
    raw_token # Return raw token for email
  end

  sig { returns(T::Boolean) }
  def reset_password_token_valid?
    reset_password_sent_at.present? && T.must(reset_password_sent_at) > 2.hours.ago
  end

  sig { void }
  def clear_reset_password_token!
    self.reset_password_token = nil
    self.reset_password_sent_at = nil
    save!
  end

  sig { params(raw_token: T.nilable(String)).returns(T.nilable(OmniAuthIdentity)) }
  def self.find_by_reset_password_token(raw_token)
    return nil if raw_token.blank?
    hashed_token = Digest::SHA256.hexdigest(raw_token)
    find_by(reset_password_token: hashed_token)
  end

  sig { params(new_password: String).void }
  def update_password!(new_password)
    self.password = new_password
    self.password_confirmation = new_password
    clear_reset_password_token!
    save!
  end

  sig { void }
  def password_valid?
    # Passwords themselves are not persisted in the database, only the digest.
    # If password is nil and password_digest is not nil, that means the record has already been saved in the db.
    return if password.nil? && password_digest.present?
    return if password.present? && password.length >= 14

    errors.add(:password, "must be at least 14 characters long")
  end

  sig { void }
  def password_not_common
    return if password.nil?
    return if password_digest.present? && !password_digest_changed?

    if COMMON_PASSWORDS.include?(password.downcase)
      errors.add(:password, "is too common. Please choose a more unique password.")
    end
  end
end
