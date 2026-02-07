# typed: true

class TrusteeGrant < ApplicationRecord
  extend T::Sig
  include HasTruncatedId

  # Capability definitions for trustee grants
  CAPABILITIES = T.let({
    "create_notes" => { name: "Create notes", category: "content" },
    "create_decisions" => { name: "Create decisions", category: "content" },
    "create_commitments" => { name: "Create commitments", category: "content" },
    "vote" => { name: "Vote on decisions", category: "participation" },
    "commit" => { name: "Join commitments", category: "participation" },
    "comment" => { name: "Add comments", category: "participation" },
    "edit_own_content" => { name: "Edit trustee's content", category: "management" },
    "pin" => { name: "Pin/unpin content", category: "management" },
  }.freeze, T::Hash[String, T::Hash[Symbol, String]])

  belongs_to :tenant
  belongs_to :trustee_user, class_name: "User"
  belongs_to :granting_user, class_name: "User"
  belongs_to :trusted_user, class_name: "User"

  has_many :representation_sessions, dependent: :restrict_with_error, inverse_of: :trustee_grant

  before_validation :create_trustee_user!, on: :create

  validate :all_users_conform_to_expectations

  # =========================================================================
  # STATE METHODS
  # =========================================================================

  sig { returns(T::Boolean) }
  def pending?
    accepted_at.nil? && declined_at.nil? && revoked_at.nil?
  end

  sig { returns(T::Boolean) }
  def active?
    accepted_at.present? && declined_at.nil? && revoked_at.nil? && !expired?
  end

  sig { returns(T::Boolean) }
  def declined?
    declined_at.present?
  end

  sig { returns(T::Boolean) }
  def revoked?
    revoked_at.present?
  end

  sig { returns(T::Boolean) }
  def expired?
    expires_at.present? && T.must(expires_at) < Time.current
  end

  # =========================================================================
  # STATE TRANSITION METHODS
  # =========================================================================

  sig { void }
  def accept!
    raise "Cannot accept: not pending" unless pending?

    update!(accepted_at: Time.current)
    # TODO: Send notification to granting_user
  end

  sig { void }
  def decline!
    raise "Cannot decline: not pending" unless pending?

    update!(declined_at: Time.current)
    # TODO: Send notification to granting_user
  end

  sig { void }
  def revoke!
    raise "Cannot revoke: already revoked or declined" if revoked? || declined?

    update!(revoked_at: Time.current)
    # TODO: Send notification to trusted_user
  end

  # =========================================================================
  # CAPABILITY METHODS
  # =========================================================================

  sig { params(capability: String).returns(T::Boolean) }
  def has_capability?(capability)
    permissions&.dig(capability) == true
  end

  # =========================================================================
  # STUDIO SCOPING METHODS
  # =========================================================================

  sig { params(superagent: Superagent).returns(T::Boolean) }
  def allows_studio?(superagent)
    scope = studio_scope || { "mode" => "all" }
    case scope["mode"]
    when "all"
      true
    when "include"
      scope["studio_ids"]&.include?(superagent.id) || false
    when "exclude"
      !scope["studio_ids"]&.include?(superagent.id)
    else
      false
    end
  end

  # =========================================================================
  # SCOPES
  # =========================================================================

  scope :pending, -> { where(accepted_at: nil, declined_at: nil, revoked_at: nil) }
  scope :active, lambda {
    where.not(accepted_at: nil)
      .where(declined_at: nil, revoked_at: nil)
      .where("expires_at IS NULL OR expires_at > ?", Time.current)
  }

  sig { returns(String) }
  def display_name
    trusted_name = trusted_user&.display_name || trusted_user&.name || "Unknown"
    granting_name = granting_user&.display_name || granting_user&.name || "Unknown"
    T.must(relationship_phrase).gsub("{trusted_user}", trusted_name).gsub("{granting_user}", granting_name)
  end

  # Override ApplicationRecord#path - TrusteeGrant paths are user-relative, not superagent-relative
  sig { override.returns(T.nilable(String)) }
  def path
    # Use granting_user's handle since that's the primary owner of the trustee grant
    handle = granting_user&.tenant_users&.first&.handle
    return nil unless handle

    "/u/#{handle}/settings/trustee-grants/#{truncated_id}"
  end

  sig { void }
  def create_trustee_user!
    return if trustee_user

    self.trustee_user = User.create!(
      name: display_name,
      email: "#{SecureRandom.uuid}@not-a-real-email.com",
      user_type: "trustee"
    )
  end

  sig { void }
  def all_users_conform_to_expectations
    errors.add(:trustee_user, "must be a trustee user") unless T.must(trustee_user).trustee?
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
    return unless T.must(trusted_user).trustee?

    errors.add(:trusted_user, "cannot be a trustee user")
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
