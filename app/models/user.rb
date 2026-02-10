# typed: true

class User < ApplicationRecord
  extend T::Sig

  include HasImage
  include HasGlobalRoles
  self.implicit_order_column = "created_at"
  has_many :oauth_identities
  has_many :decision_participants
  has_many :votes, through: :decision_participants
  has_many :commitment_participants
  has_many :note_history_events
  has_many :tenant_users
  has_many :tenants, through: :tenant_users
  has_many :superagent_members
  has_many :superagents, through: :superagent_members
  has_many :api_tokens
  has_many :subagents, class_name: "User", foreign_key: "parent_id"
  has_many :notification_recipients
  has_many :notifications, through: :notification_recipients

  # Trustee grant associations
  # granted_trustee_grants: grants where this user is the granting party (e.g., a subagent granting authority)
  has_many :granted_trustee_grants, class_name: "TrusteeGrant",
                                    foreign_key: "granting_user_id", inverse_of: :granting_user,
                                    dependent: :destroy
  # received_trustee_grants: grants where this user is the trustee (authorized to act on behalf of grantor)
  has_many :received_trustee_grants, class_name: "TrusteeGrant",
                                     foreign_key: "trustee_user_id", inverse_of: :trustee_user,
                                     dependent: :destroy

  # Auto-create TrusteeGrant when a subagent is created
  after_create :create_parent_trustee_grant!, if: :subagent?

  validates :user_type, inclusion: { in: ["person", "subagent", "superagent_proxy"] }
  validates :email, presence: true
  validates :name, presence: true
  validate :subagent_must_have_parent

  # Clear memoized associations on reload
  sig { params(options: T.untyped).returns(User) }
  def reload(options = nil)
    remove_instance_variable(:@tenant_user) if defined?(@tenant_user)
    remove_instance_variable(:@superagent_member) if defined?(@superagent_member)
    remove_instance_variable(:@proxy_superagent) if defined?(@proxy_superagent)
    remove_instance_variable(:@superagents) if defined?(@superagents)
    super
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def api_json
    {
      id: id,
      user_type: user_type,
      email: email,
      display_name: display_name,
      handle: handle,
      image_url: image_url,
      # settings: settings, # only show settings for own user
      pinned_items: pinned_items,
      created_at: created_at,
      updated_at: updated_at,
      archived_at: archived_at,
    }
  end

  sig { returns(T.nilable(String)) }
  def truncated_id
    handle
  end

  sig { returns(T.nilable(String)) }
  def image_url
    if superagent_proxy?
      Superagent.where(proxy_user: self).first&.image_path
    else
      image_path_no_placeholder || super || image_path
    end
  end

  sig { void }
  def subagent_must_have_parent
    if parent_id.present? && !subagent?
      errors.add(:parent_id, "can only be set for subagent users")
    elsif parent_id.nil? && subagent?
      errors.add(:parent_id, "must be set for subagent users")
    end
    return unless persisted? && parent_id == id

    errors.add(:parent_id, "user cannot be its own parent")
  end

  sig { returns(T::Boolean) }
  def person?
    user_type == "person"
  end

  sig { returns(T::Boolean) }
  def subagent?
    user_type == "subagent"
  end

  sig { returns(T::Boolean) }
  def internal_subagent?
    subagent? && agent_configuration&.dig("mode") == "internal"
  end

  sig { returns(T::Boolean) }
  def external_subagent?
    subagent? && !internal_subagent?
  end

  sig { returns(T::Boolean) }
  def superagent_proxy?
    user_type == "superagent_proxy"
  end

  # Returns the superagent this user is a proxy for, if any
  sig { returns(T.nilable(Superagent)) }
  def proxy_superagent
    return nil unless superagent_proxy?
    return @proxy_superagent if defined?(@proxy_superagent)

    @proxy_superagent = Superagent.where(proxy_user: self).first
  end

  # Check if this user is authorized to use the given proxy identity.
  # Used to validate that a proxy_user_id in the session is legitimate.
  #
  # Superagent proxy users represent studios for collective agency.
  # TrusteeGrants authorize users to act on behalf of other users (a separate concept).
  sig { params(proxy_user: User).returns(T::Boolean) }
  def is_trusted_as?(proxy_user)
    return false unless proxy_user.superagent_proxy?
    return false unless proxy_user.proxy_superagent.present?

    superagent = proxy_user.proxy_superagent
    return false unless superagent

    can_represent?(superagent)
  end

  sig { params(superagent_or_user: T.any(Superagent, User)).returns(T::Boolean) }
  def can_represent?(superagent_or_user)
    if superagent_or_user.is_a?(Superagent)
      superagent = superagent_or_user
      is_proxy_of_superagent = proxy_superagent == superagent
      return is_proxy_of_superagent if superagent_proxy?

      sm = superagent_members.find_by(superagent_id: superagent.id)
      return sm&.can_represent? || false
    elsif superagent_or_user.is_a?(User)
      user = superagent_or_user
      # Cannot represent archived users
      return false if user.archived?

      # Parent can represent their subagent
      return true if is_parent_of?(user)

      # Check if self can represent user's superagent proxy
      if user.superagent_proxy?
        sm = superagent_members.find_by(superagent_id: T.must(user.proxy_superagent).id)
        return sm&.can_represent? || false
      end

      # The trustee_user (self) can represent the granting_user (user) if there's an active grant
      grant = TrusteeGrant.active.find_by(
        granting_user: user,
        trustee_user: self
      )
      return grant.present?
    end
    false
  end

  # Returns pending trustee grant requests where this user is the trusted_user
  sig { returns(ActiveRecord::Relation) }
  def pending_trustee_grant_requests
    received_trustee_grants.pending
  end

  sig { params(user: User).returns(T::Boolean) }
  def can_edit?(user)
    user == self || (user.subagent? && user.parent_id == id)
  end

  sig { params(subagent: User, superagent: Superagent).returns(T::Boolean) }
  def can_add_subagent_to_superagent?(subagent, superagent)
    return false unless subagent.subagent? && subagent.parent_id == id

    sm = superagent_members.find_by(superagent_id: superagent.id)
    sm&.can_invite? || false
  end

  sig { void }
  def archive!
    T.must(tenant_user).archive!
  end

  sig { void }
  def unarchive!
    T.must(tenant_user).unarchive!
  end

  sig { returns(T::Boolean) }
  def archived?
    T.must(tenant_user).archived?
  end

  sig { returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def archived_at
    T.must(tenant_user).archived_at
  end

  sig { params(tu: TenantUser).void }
  def tenant_user=(tu)
    raise "TenantUser user_id does not match User id" unless tu.user_id == id

    @tenant_user = tu
  end

  sig { returns(T.nilable(TenantUser)) }
  def tenant_user
    @tenant_user ||= tenant_users.where(tenant_id: Tenant.current_id).first
  end

  # Returns all tenants this user is a member of, across all tenants.
  # This is a cross-tenant query but is safe because it only returns the user's own data.
  sig { returns(T::Array[Tenant]) }
  def own_tenants
    TenantUser.for_user_across_tenants(self)
      .where(archived_at: nil)
      .includes(:tenant)
      .where(tenant: { archived_at: nil })
      .map(&:tenant)
  end

  sig { void }
  def save_tenant_user!
    T.must(tenant_user).save!
  end

  sig { params(sm: SuperagentMember).void }
  def superagent_member=(sm)
    raise "SuperagentMember user_id does not match User id" unless sm.user_id == id

    @superagent_member = sm
  end

  sig { returns(T.nilable(SuperagentMember)) }
  def superagent_member
    @superagent_member ||= superagent_members.where(superagent_id: Superagent.current_id).first
  end

  sig { void }
  def save_superagent_member!
    T.must(superagent_member).save!
  end

  sig { returns(ActiveRecord::Relation) }
  def superagents
    @superagents ||= Superagent.joins(:superagent_members).where(superagent_members: { user_id: id })
  end

  sig { params(name: String).void }
  def display_name=(name)
    T.must(tenant_user).display_name = name
  end

  sig { returns(T.nilable(String)) }
  def display_name
    if superagent_proxy?
      Superagent.where(proxy_user: self).first&.name
    else
      tenant_user&.display_name
    end
  end

  sig { returns(String) }
  def display_name_with_parent
    return display_name || "" unless subagent?

    parent_name = parent&.display_name || "unknown"
    "#{display_name} (subagent of #{parent_name})"
  end

  sig { returns(T.nilable(User)) }
  def parent
    return nil unless parent_id

    User.find_by(id: parent_id)
  end

  sig { params(handle: String).void }
  def handle=(handle)
    T.must(tenant_user).handle = handle
  end

  sig { returns(T.nilable(String)) }
  def handle
    if superagent_proxy?
      superagent = Superagent.where(proxy_user: self).first
      superagent ? "studios/" + T.must(superagent.handle) : nil
    else
      tenant_user&.handle
    end
  end

  sig { returns(T.nilable(String)) }
  def path
    if superagent_proxy?
      Superagent.where(proxy_user: self).first&.path
    else
      tenant_user&.path
    end
  end

  sig { returns(T.untyped) }
  def settings
    T.must(tenant_user).settings
  end

  sig { returns(T.untyped) }
  def pinned_items
    T.must(tenant_user).pinned_items
  end

  sig { params(item: T.untyped).void }
  def pin_item!(item)
    T.must(tenant_user).pin_item!(item)
  end

  sig { params(item: T.untyped).void }
  def unpin_item!(item)
    T.must(tenant_user).unpin_item!(item)
  end

  sig { params(item: T.untyped).returns(T::Boolean) }
  def has_pinned?(item)
    T.must(tenant_user).has_pinned?(item)
  end

  sig { params(limit: Integer).returns(T.untyped) }
  def confirmed_read_note_events(limit: 10)
    T.must(tenant_user).confirmed_read_note_events(limit: limit)
  end

  sig { returns(ActiveRecord::Relation) }
  def api_tokens
    ApiToken.where(user_id: id, tenant_id: T.must(tenant_user).tenant_id, deleted_at: nil)
  end

  sig { params(invite: Invite).returns(SuperagentMember) }
  def accept_invite!(invite)
    raise "Cannot accept invite for another user" unless invite.invited_user_id == id || invite.invited_user_id.nil?

    SuperagentMember.find_or_create_by!(superagent_id: invite.superagent_id, user_id: id)
    # TODO: track invite accepted event
  end

  sig { returns(ActiveRecord::Relation) }
  def superagents_minus_main
    superagents.includes(:tenant).where("tenants.main_superagent_id != superagents.id")
  end

  sig { returns(ActiveRecord::Relation) }
  def external_oauth_identities
    oauth_identities.where.not(provider: "identity")
  end

  sig { returns(T.nilable(OmniAuthIdentity)) }
  def omni_auth_identity
    OmniAuthIdentity.find_by(email: email)
  end

  sig { returns(OmniAuthIdentity) }
  def find_or_create_omni_auth_identity!
    oaid = omni_auth_identity
    if oaid.nil?
      oaid = OmniAuthIdentity.create!(
        email: email,
        name: name,
        password: SecureRandom.alphanumeric(32)
      )
    end
    oaid
  end

  # Suspension methods

  sig { returns(T::Boolean) }
  def suspended?
    suspended_at.present?
  end

  sig { params(by: User, reason: String).void }
  def suspend!(by:, reason:)
    update!(
      suspended_at: Time.current,
      suspended_by_id: by.id,
      suspended_reason: reason
    )

    # Cross-tenant soft-delete of all API tokens for this user.
    # Security: Ensures suspended user cannot use any existing tokens.
    # Authorization: Callers must verify admin privileges before calling suspend!
    # (e.g., AdminController.ensure_admin_user checks tenant-level admin role)
    ApiToken.for_user_across_tenants(self).where(deleted_at: nil).find_each(&:delete!)

    # Recursively suspend all subagents
    subagents.where(suspended_at: nil).find_each do |subagent|
      subagent.suspend!(by: by, reason: "Parent user suspended: #{reason}")
    end
  end

  sig { void }
  def unsuspend!
    update!(
      suspended_at: nil,
      suspended_by_id: nil,
      suspended_reason: nil
    )
  end

  sig { returns(T.nilable(User)) }
  def suspended_by
    return nil unless suspended_by_id

    User.find_by(id: suspended_by_id)
  end

  # Social proximity methods

  sig { params(other_user: User, tenant_id: T.nilable(String)).returns(Float) }
  def social_proximity_to(other_user, tenant_id: Tenant.current_id)
    return 0.0 if tenant_id.nil?

    scores = cached_proximity_scores(tenant_id)
    scores[other_user.id] || 0.0
  end

  sig { params(tenant_id: T.nilable(String), limit: Integer).returns(T::Array[T::Array[T.untyped]]) }
  def most_proximate_users(tenant_id: Tenant.current_id, limit: 20)
    return [] if tenant_id.nil?

    cached_proximity_scores(tenant_id)
      .sort_by { |_id, score| -score }
      .first(limit)
      .map { |uid, score| [User.find_by(id: uid), score] }
      .reject { |user, _| user.nil? }
  end

  private

  # Check if self is the parent of the given user (for representation)
  sig { params(user: User).returns(T::Boolean) }
  def is_parent_of?(user)
    user.subagent? && user.parent_id == id && !user.archived?
  end

  # Create a TrusteeGrant allowing the parent to represent this subagent
  sig { void }
  def create_parent_trustee_grant!
    return unless subagent? && parent_id.present?

    parent_user = User.find_by(id: parent_id)
    return unless parent_user

    # Build permissions hash with all grantable actions
    all_permissions = TrusteeGrant::GRANTABLE_ACTIONS.index_with { true }

    TrusteeGrant.create!(
      granting_user: self,              # The subagent grants
      trustee_user: parent_user,        # The parent is the trustee
      accepted_at: Time.current,        # Pre-accepted
      permissions: all_permissions,     # All actions allowed
      studio_scope: { "mode" => "all" } # All studios
    )
  end

  sig { params(tenant_id: String).returns(T::Hash[String, Float]) }
  def cached_proximity_scores(tenant_id)
    Rails.cache.fetch("proximity:#{tenant_id}:#{id}", expires_in: 1.day) do
      SocialProximityCalculator.new(self, tenant_id: tenant_id).compute
    end
  end
end
