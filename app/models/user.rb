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

  validates :user_type, inclusion: { in: %w(person subagent trustee) }
  validates :email, presence: true
  validates :name, presence: true
  validate :subagent_must_have_parent

  # Clear memoized associations on reload
  sig { params(options: T.untyped).returns(User) }
  def reload(options = nil)
    remove_instance_variable(:@tenant_user) if defined?(@tenant_user)
    remove_instance_variable(:@superagent_member) if defined?(@superagent_member)
    remove_instance_variable(:@trustee_superagent) if defined?(@trustee_superagent)
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
    if trustee?
      Superagent.where(trustee_user: self).first&.image_path
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
    if persisted? && parent_id == id
      errors.add(:parent_id, "user cannot be its own parent")
    end
  end

  sig { returns(T::Boolean) }
  def person?
    user_type == 'person'
  end

  sig { returns(T::Boolean) }
  def subagent?
    user_type == "subagent"
  end

  sig { returns(T::Boolean) }
  def trustee?
    user_type == 'trustee'
  end

  sig { returns(T::Boolean) }
  def superagent_trustee?
    trustee? && trustee_superagent.present?
  end

  sig { returns(T.nilable(Superagent)) }
  def trustee_superagent
    return nil unless trustee?
    return @trustee_superagent if defined?(@trustee_superagent)
    @trustee_superagent = Superagent.where(trustee_user: self).first
  end

  sig { params(user: User).returns(T::Boolean) }
  def can_impersonate?(user)
    is_parent = user.subagent? && user.parent_id == self.id && !user.archived?
    return true if is_parent
    if user.superagent_trustee?
      sm = self.superagent_members.find_by(superagent_id: T.must(user.trustee_superagent).id)
      return sm&.can_represent? || false
    end
    false
  end

  sig { params(superagent_or_user: T.any(Superagent, User)).returns(T::Boolean) }
  def can_represent?(superagent_or_user)
    if superagent_or_user.is_a?(Superagent)
      superagent = superagent_or_user
      is_trustee_of_superagent = self.trustee_superagent == superagent
      return is_trustee_of_superagent if self.trustee?
      sm = self.superagent_members.find_by(superagent_id: superagent.id)
      return sm&.can_represent? || false
    elsif superagent_or_user.is_a?(User)
      user = superagent_or_user
      return can_impersonate?(user)
      # TODO - check for trustee permissions for non-superagent trustee users
    end
    false
  end

  sig { params(user: User).returns(T::Boolean) }
  def can_edit?(user)
    user == self || (user.subagent? && user.parent_id == self.id)
  end

  sig { params(subagent: User, superagent: Superagent).returns(T::Boolean) }
  def can_add_subagent_to_superagent?(subagent, superagent)
    return false unless subagent.subagent? && subagent.parent_id == self.id
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
    if tu.user_id == self.id
      @tenant_user = tu
    else
      raise "TenantUser user_id does not match User id"
    end
  end

  sig { returns(T.nilable(TenantUser)) }
  def tenant_user
    @tenant_user ||= tenant_users.where(tenant_id: Tenant.current_id).first
  end

  sig { void }
  def save_tenant_user!
    T.must(tenant_user).save!
  end

  sig { params(sm: SuperagentMember).void }
  def superagent_member=(sm)
    if sm.user_id == self.id
      @superagent_member = sm
    else
      raise "SuperagentMember user_id does not match User id"
    end
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
    @superagents ||= Superagent.joins(:superagent_members).where(superagent_members: {user_id: id})
  end

  sig { params(name: String).void }
  def display_name=(name)
    T.must(tenant_user).display_name = name
  end

  sig { returns(T.nilable(String)) }
  def display_name
    if trustee?
      Superagent.where(trustee_user: self).first&.name
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
    User.unscoped.find_by(id: parent_id)
  end

  sig { params(handle: String).void }
  def handle=(handle)
    T.must(tenant_user).handle = handle
  end

  sig { returns(T.nilable(String)) }
  def handle
    if trustee?
      superagent = Superagent.where(trustee_user: self).first
      superagent ? 'studios/' + T.must(superagent.handle) : nil
    else
      tenant_user&.handle
    end
  end

  sig { returns(T.nilable(String)) }
  def path
    if trustee?
      Superagent.where(trustee_user: self).first&.path
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
    if invite.invited_user_id == self.id || invite.invited_user_id.nil?
      SuperagentMember.find_or_create_by!(superagent_id: invite.superagent_id, user_id: self.id)
      # TODO track invite accepted event
    else
      raise "Cannot accept invite for another user"
    end
  end

  sig { returns(ActiveRecord::Relation) }
  def superagents_minus_main
    superagents.includes(:tenant).where('tenants.main_superagent_id != superagents.id')
  end

  sig { returns(ActiveRecord::Relation) }
  def external_oauth_identities
    oauth_identities.where.not(provider: 'identity')
  end

  sig { returns(T.nilable(OmniAuthIdentity)) }
  def omni_auth_identity
    OmniAuthIdentity.find_by(email: self.email)
  end

  sig { returns(OmniAuthIdentity) }
  def find_or_create_omni_auth_identity!
    oaid = omni_auth_identity
    if oaid.nil?
      oaid = OmniAuthIdentity.create!(
        email: self.email,
        name: self.name,
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

    # Soft-delete all API tokens for this user (across all tenants)
    ApiToken.unscoped.where(user_id: id, deleted_at: nil).find_each(&:delete!)

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
    User.unscoped.find_by(id: suspended_by_id)
  end

end