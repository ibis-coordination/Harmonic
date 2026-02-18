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
  has_many :collective_members
  has_many :collectives, through: :collective_members
  has_many :api_tokens
  has_many :ai_agents, class_name: "User", foreign_key: "parent_id"
  has_many :notification_recipients
  has_many :notifications, through: :notification_recipients

  # Trustee grant associations
  # granted_trustee_grants: grants where this user is the granting party (e.g., an AI agent granting authority)
  has_many :granted_trustee_grants, class_name: "TrusteeGrant",
                                    foreign_key: "granting_user_id", inverse_of: :granting_user,
                                    dependent: :destroy
  # received_trustee_grants: grants where this user is the trustee (authorized to act on behalf of grantor)
  has_many :received_trustee_grants, class_name: "TrusteeGrant",
                                     foreign_key: "trustee_user_id", inverse_of: :trustee_user,
                                     dependent: :destroy

  # Auto-create TrusteeGrant when an AI agent is created
  after_create :create_parent_trustee_grant!, if: :ai_agent?

  validates :user_type, inclusion: { in: ["human", "ai_agent", "collective_proxy"] }
  validates :email, presence: true
  validates :name, presence: true
  validate :ai_agent_must_have_parent

  # Clear memoized associations on reload
  sig { params(options: T.untyped).returns(User) }
  def reload(options = nil)
    remove_instance_variable(:@tenant_user) if defined?(@tenant_user)
    remove_instance_variable(:@collective_member) if defined?(@collective_member)
    remove_instance_variable(:@proxy_collective) if defined?(@proxy_collective)
    remove_instance_variable(:@collectives) if defined?(@collectives)
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
    if collective_proxy?
      Collective.where(proxy_user: self).first&.image_path
    else
      image_path_no_placeholder || super || image_path
    end
  end

  sig { void }
  def ai_agent_must_have_parent
    if parent_id.present? && !ai_agent?
      errors.add(:parent_id, "can only be set for AI agent users")
    elsif parent_id.nil? && ai_agent?
      errors.add(:parent_id, "must be set for AI agent users")
    end
    return unless persisted? && parent_id == id

    errors.add(:parent_id, "user cannot be its own parent")
  end

  sig { returns(T::Boolean) }
  def human?
    user_type == "human"
  end

  sig { returns(T::Boolean) }
  def ai_agent?
    user_type == "ai_agent"
  end

  sig { returns(T::Boolean) }
  def internal_ai_agent?
    ai_agent? && agent_configuration&.dig("mode") == "internal"
  end

  sig { returns(T::Boolean) }
  def external_ai_agent?
    ai_agent? && !internal_ai_agent?
  end

  sig { returns(T::Boolean) }
  def collective_proxy?
    user_type == "collective_proxy"
  end

  # Returns the collective this user is a proxy for, if any
  sig { returns(T.nilable(Collective)) }
  def proxy_collective
    return nil unless collective_proxy?
    return @proxy_collective if defined?(@proxy_collective)

    @proxy_collective = Collective.where(proxy_user: self).first
  end

  # Check if this user is authorized to use the given proxy identity.
  # Used to validate that a proxy_user_id in the session is legitimate.
  #
  # Collective proxy users represent studios for collective agency.
  # TrusteeGrants authorize users to act on behalf of other users (a separate concept).
  sig { params(proxy_user: User).returns(T::Boolean) }
  def is_trusted_as?(proxy_user)
    return false unless proxy_user.collective_proxy?
    return false unless proxy_user.proxy_collective.present?

    collective = proxy_user.proxy_collective
    return false unless collective

    can_represent?(collective)
  end

  sig { params(collective_or_user: T.any(Collective, User)).returns(T::Boolean) }
  def can_represent?(collective_or_user)
    if collective_or_user.is_a?(Collective)
      collective = collective_or_user
      is_proxy_of_collective = proxy_collective == collective
      return is_proxy_of_collective if collective_proxy?

      cm = collective_members.find_by(collective_id: collective.id)
      return cm&.can_represent? || false
    elsif collective_or_user.is_a?(User)
      user = collective_or_user
      # Cannot represent archived users
      return false if user.archived?

      # Parent can represent their AI agent
      return true if is_parent_of?(user)

      # Check if self can represent user's collective proxy
      if user.collective_proxy?
        cm = collective_members.find_by(collective_id: T.must(user.proxy_collective).id)
        return cm&.can_represent? || false
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
    user == self || (user.ai_agent? && user.parent_id == id)
  end

  sig { params(ai_agent: User, collective: Collective).returns(T::Boolean) }
  def can_add_ai_agent_to_collective?(ai_agent, collective)
    return false unless ai_agent.ai_agent? && ai_agent.parent_id == id

    cm = collective_members.find_by(collective_id: collective.id)
    cm&.can_invite? || false
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

  sig { params(cm: CollectiveMember).void }
  def collective_member=(cm)
    raise "CollectiveMember user_id does not match User id" unless cm.user_id == id

    @collective_member = cm
  end

  sig { returns(T.nilable(CollectiveMember)) }
  def collective_member
    @collective_member ||= collective_members.where(collective_id: Collective.current_id).first
  end

  sig { void }
  def save_collective_member!
    T.must(collective_member).save!
  end

  sig { returns(ActiveRecord::Relation) }
  def collectives
    @collectives ||= Collective.joins(:collective_members).where(collective_members: { user_id: id })
  end

  sig { params(name: String).void }
  def display_name=(name)
    T.must(tenant_user).display_name = name
  end

  sig { returns(T.nilable(String)) }
  def display_name
    if collective_proxy?
      Collective.where(proxy_user: self).first&.name
    else
      tenant_user&.display_name
    end
  end

  sig { returns(String) }
  def display_name_with_parent
    return display_name || "" unless ai_agent?

    parent_name = parent&.display_name || "unknown"
    "#{display_name} (AI agent of #{parent_name})"
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
    if collective_proxy?
      collective = Collective.where(proxy_user: self).first
      collective ? "studios/" + T.must(collective.handle) : nil
    else
      tenant_user&.handle
    end
  end

  sig { returns(T.nilable(String)) }
  def path
    if collective_proxy?
      Collective.where(proxy_user: self).first&.path
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

  sig { params(invite: Invite).returns(CollectiveMember) }
  def accept_invite!(invite)
    raise "Cannot accept invite for another user" unless invite.invited_user_id == id || invite.invited_user_id.nil?

    CollectiveMember.find_or_create_by!(collective_id: invite.collective_id, user_id: id)
    # TODO: track invite accepted event
  end

  sig { returns(ActiveRecord::Relation) }
  def collectives_minus_main
    collectives.includes(:tenant).where("tenants.main_collective_id != collectives.id")
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

    # Recursively suspend all AI agents
    ai_agents.where(suspended_at: nil).find_each do |ai_agent|
      ai_agent.suspend!(by: by, reason: "Parent user suspended: #{reason}")
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
    user.ai_agent? && user.parent_id == id && !user.archived?
  end

  # Create a TrusteeGrant allowing the parent to represent this AI agent
  sig { void }
  def create_parent_trustee_grant!
    return unless ai_agent? && parent_id.present?

    parent_user = User.find_by(id: parent_id)
    return unless parent_user

    # Build permissions hash with all grantable actions
    all_permissions = TrusteeGrant::GRANTABLE_ACTIONS.index_with { true }

    TrusteeGrant.create!(
      granting_user: self,              # The AI agent grants
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
