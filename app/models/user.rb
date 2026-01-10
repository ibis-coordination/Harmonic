# typed: true

class User < ApplicationRecord
  extend T::Sig

  include HasImage
  self.implicit_order_column = "created_at"
  has_many :oauth_identities
  has_many :decision_participants
  has_many :votes, through: :decision_participants
  has_many :commitment_participants
  has_many :note_history_events
  has_many :tenant_users
  has_many :tenants, through: :tenant_users
  has_many :studio_users
  has_many :studios, through: :studio_users
  has_many :api_tokens
  has_many :subagents, class_name: "User", foreign_key: "parent_id"

  validates :user_type, inclusion: { in: %w(person subagent trustee) }
  validates :email, presence: true
  validates :name, presence: true
  validate :subagent_must_have_parent

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
      Studio.where(trustee_user: self).first&.image_path
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
  def studio_trustee?
    trustee? && trustee_studio.present?
  end

  sig { returns(T.nilable(Studio)) }
  def trustee_studio
    return nil unless trustee?
    return @trustee_studio if defined?(@trustee_studio)
    @trustee_studio = Studio.where(trustee_user: self).first
  end

  sig { params(user: User).returns(T::Boolean) }
  def can_impersonate?(user)
    is_parent = user.subagent? && user.parent_id == self.id && !user.archived?
    return true if is_parent
    if user.studio_trustee?
      su = self.studio_users.find_by(studio_id: T.must(user.trustee_studio).id)
      return su&.can_represent? || false
    end
    false
  end

  sig { params(studio_or_user: T.any(Studio, User)).returns(T::Boolean) }
  def can_represent?(studio_or_user)
    if studio_or_user.is_a?(Studio)
      studio = studio_or_user
      is_trustee_of_studio = self.trustee_studio == studio
      return is_trustee_of_studio if self.trustee?
      su = self.studio_users.find_by(studio_id: studio.id)
      return su&.can_represent? || false
    elsif studio_or_user.is_a?(User)
      user = studio_or_user
      return can_impersonate?(user)
      # TODO - check for trustee permissions for non-studio trustee users
    end
    false
  end

  sig { params(user: User).returns(T::Boolean) }
  def can_edit?(user)
    user == self || (user.subagent? && user.parent_id == self.id)
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

  sig { params(su: StudioUser).void }
  def studio_user=(su)
    if su.user_id == self.id
      @studio_user = su
    else
      raise "studioUser user_id does not match User id"
    end
  end

  sig { returns(T.nilable(StudioUser)) }
  def studio_user
    @studio_user ||= studio_users.where(studio_id: Studio.current_id).first
  end

  sig { void }
  def save_studio_user!
    T.must(studio_user).save!
  end

  sig { returns(ActiveRecord::Relation) }
  def studios
    @studios ||= Studio.joins(:studio_users).where(studio_users: {user_id: id})
  end

  sig { params(name: String).void }
  def display_name=(name)
    T.must(tenant_user).display_name = name
  end

  sig { returns(T.nilable(String)) }
  def display_name
    if trustee?
      Studio.where(trustee_user: self).first&.name
    else
      tenant_user&.display_name
    end
  end

  sig { params(handle: String).void }
  def handle=(handle)
    T.must(tenant_user).handle = handle
  end

  sig { returns(T.nilable(String)) }
  def handle
    if trustee?
      studio = Studio.where(trustee_user: self).first
      studio ? 'studios/' + T.must(studio.handle) : nil
    else
      tenant_user&.handle
    end
  end

  sig { returns(T.nilable(String)) }
  def path
    if trustee?
      Studio.where(trustee_user: self).first&.path
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

  sig { params(studio_invite: StudioInvite).returns(StudioUser) }
  def accept_invite!(studio_invite)
    if studio_invite.invited_user_id == self.id || studio_invite.invited_user_id.nil?
      StudioUser.find_or_create_by!(studio_id: studio_invite.studio_id, user_id: self.id)
      # TODO track invite accepted event
    else
      raise "Cannot accept invite for another user"
    end
  end

  sig { returns(ActiveRecord::Relation) }
  def studios_minus_main
    studios.includes(:tenant).where('tenants.main_studio_id != studios.id')
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

end