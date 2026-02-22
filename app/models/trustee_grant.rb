# typed: true

class TrusteeGrant < ApplicationRecord
  extend T::Sig
  include HasTruncatedId

  # Actions that can be granted to trustees
  # Uses actual action names from ActionsHelper::ACTION_DEFINITIONS
  GRANTABLE_ACTIONS = T.let([
    "create_note",
    "update_note",
    "create_decision",
    "update_decision_settings",
    "create_commitment",
    "update_commitment_settings",
    "vote",
    "add_options",
    "join_commitment",
    "add_comment",
    "pin_note",
    "unpin_note",
    "pin_decision",
    "unpin_decision",
    "pin_commitment",
    "unpin_commitment",
    "send_heartbeat",
  ].freeze, T::Array[String])

  belongs_to :tenant
  belongs_to :granting_user, class_name: "User"
  # trustee_user is the actual person trusted to act on behalf of granting_user
  # (After migration, this replaces the old trusted_user column)
  belongs_to :trustee_user, class_name: "User"

  has_many :representation_sessions, dependent: :restrict_with_error, inverse_of: :trustee_grant

  validate :all_users_conform_to_expectations
  validate :no_duplicate_active_grant, on: :create

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
    # TODO: Send notification to trustee_user
  end

  # =========================================================================
  # ACTION PERMISSION METHODS
  # =========================================================================

  # Check if this grant allows the specified action
  # @param action_name [String] Action name from ActionsHelper::ACTION_DEFINITIONS
  # @return [Boolean] true if allowed
  sig { params(action_name: String).returns(T::Boolean) }
  def has_action_permission?(action_name)
    return true if permissions.nil?  # nil = all allowed (backwards compatible)
    permissions[action_name] == true
  end

  # =========================================================================
  # STUDIO SCOPING METHODS
  # =========================================================================

  sig { params(collective: Collective).returns(T::Boolean) }
  def allows_studio?(collective)
    scope = studio_scope || { "mode" => "all" }
    case scope["mode"]
    when "all"
      true
    when "include"
      scope["studio_ids"]&.include?(collective.id) || false
    when "exclude"
      !scope["studio_ids"]&.include?(collective.id)
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
    trustee_name = trustee_user&.display_name || trustee_user&.name || "Unknown"
    granting_name = granting_user&.display_name || granting_user&.name || "Unknown"
    "#{trustee_name} on behalf of #{granting_name}"
  end

  # Override ApplicationRecord#path - TrusteeGrant paths are user-relative, not collective-relative
  sig { override.returns(T.nilable(String)) }
  def path
    # Use granting_user's handle since that's the primary owner of the trustee grant
    handle = granting_user&.tenant_users&.first&.handle
    return nil unless handle

    "/u/#{handle}/settings/trustee-grants/#{truncated_id}"
  end

  sig { void }
  def all_users_conform_to_expectations
    # Trustee user cannot be the same as granting user
    if granting_user == trustee_user
      errors.add(:trustee_user, "cannot be the same as the granting user")
    end

    # Trustee user cannot be a collective_identity (only real persons can be trustees)
    if trustee_user&.collective_identity?
      errors.add(:trustee_user, "cannot be a collective identity user")
    end

    # If granting_user is a collective identity, trustee_user must be a member of that collective
    if granting_user&.collective_identity? && granting_user&.identity_collective.present?
      unless granting_user&.identity_collective&.users&.include?(trustee_user)
        errors.add(:trustee_user, "must be a member of the collective that the granting user represents")
      end
    elsif granting_user&.collective_identity?
      # Collective identity users must have an associated collective to be granting users
      errors.add(:granting_user, "must have an associated collective if the granting user is a collective identity")
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

  private

  sig { void }
  def no_duplicate_active_grant
    return if declined_at.present? || revoked_at.present?

    existing = TrusteeGrant.where(
      granting_user_id: granting_user_id,
      trustee_user_id: trustee_user_id,
      declined_at: nil,
      revoked_at: nil,
    ).where.not(id: id)

    if existing.exists?
      errors.add(:base, "A grant already exists for this user pair")
    end
  end
end
