# typed: true

class Superagent < ApplicationRecord
  extend T::Sig

  include CanPin
  include HasImage
  include HasFeatureFlags
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :created_by, class_name: 'User'
  belongs_to :updated_by, class_name: 'User'
  belongs_to :trustee_user, class_name: 'User'
  before_validation :create_trustee!
  before_create :set_defaults
  tables = ActiveRecord::Base.connection.tables - [
    'tenants', 'users', 'tenant_users',
    'superagents', 'api_tokens', 'oauth_identities',
    # Rails internal tables
    'ar_internal_metadata', 'schema_migrations',
    'active_storage_attachments', 'active_storage_blobs',
    'active_storage_variant_records',
  ]
  tables.each do |table|
    has_many table.to_sym
  end
  has_many :users, through: :superagent_members
  validates :superagent_type, inclusion: { in: %w[studio scene] }
  validate :handle_is_valid
  validate :creator_is_not_trustee, on: :create

  # NOTE: This is commented out because there is a bug where
  # the corresponding note history event is not created
  # when the note itself is created within a callback.
  # So we rely on the controller to create the welcome note.
  # after_create :create_welcome_note!

  sig { params(subdomain: String, handle: T.nilable(String)).returns(Superagent) }
  def self.scope_thread_to_superagent(subdomain:, handle:)
    # In single-tenant mode, treat empty/blank subdomain as PRIMARY_SUBDOMAIN
    if Tenant.single_tenant_mode? && subdomain.blank?
      subdomain = Tenant.single_tenant_subdomain.to_s
    end

    tenant = Tenant.scope_thread_to_tenant(subdomain: subdomain)
    superagent = handle ? tenant.superagents.find_by!(handle: handle) : tenant.main_superagent
    if superagent.nil? && subdomain == ENV['AUTH_SUBDOMAIN']
      # This is a special case for the auth subdomain.
      # We only need a temporary superagent object to set the thread scope.
      # It will not be persisted to the database.
      superagent = Superagent.new(
        id: SecureRandom.uuid,
        name: 'Harmonic',
        handle: SecureRandom.hex(16),
        tenant: tenant,
      )
      tenant.main_superagent = superagent
    elsif superagent.nil? && tenant.main_superagent.nil?
      raise ActiveRecord::RecordNotFound, "Tenant with subdomain '#{subdomain}' is missing a main superagent"
    elsif superagent.nil?
      raise ActiveRecord::RecordNotFound, "Superagent with handle '#{handle}' not found"
    end
    Thread.current[:superagent_id] = superagent.id
    Thread.current[:superagent_handle] = superagent.handle
    superagent
  end

  sig { void }
  def self.clear_thread_scope
    Thread.current[:superagent_id] = nil
    Thread.current[:superagent_handle] = nil
  end

  sig { returns(T.nilable(String)) }
  def self.current_handle
    Thread.current[:superagent_handle]
  end

  sig { returns(T.nilable(String)) }
  def self.current_id
    Thread.current[:superagent_id]
  end

  sig { params(handle: String).returns(T::Boolean) }
  def self.handle_available?(handle)
    Superagent.where(handle: handle).count == 0
  end

  sig { void }
  def set_defaults
    self.updated_by ||= self.created_by
    self.settings = {
      unlisted: true,
      invite_only: true,
      timezone: 'UTC',
      all_members_can_invite: false,
      any_member_can_represent: false,
      tempo: 'weekly',
      synchronization_mode: 'improv',
      allow_file_uploads: true,
      file_upload_limit: 100.megabytes,
      pinned: {},
      feature_flags: {
        api: false,
      },
    }.merge(
      T.must(self.tenant).default_studio_settings
    ).merge(
      self.settings || {}
    )
  end

  sig { returns(T::Boolean) }
  def is_main_superagent?
    T.must(self.tenant).main_superagent_id == self.id
  end

  sig { returns(T::Boolean) }
  def is_scene?
    superagent_type == 'scene'
  end

  sig { params(value: T::Boolean).void }
  def open_scene=(value)
    if value == true || value == false
      self.settings = (self.settings || {}).merge('open_scene' => value)
    else
      errors.add(:settings, "'open_scene' must be a boolean")
    end
  end

  sig { returns(T::Boolean) }
  def scene_is_open?
    # An open scene is a scene that does not require an invite to join
    is_scene? && settings['open_scene'] == true
  end

  sig { returns(T::Boolean) }
  def scene_is_invite_only?
    is_scene? && !scene_is_open?
  end

  sig { void }
  def creator_is_not_trustee
    errors.add(:created_by, "cannot be a trustee") if created_by&.trustee?
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    {
      id: id,
      name: name,
      handle: handle,
      timezone: timezone.name,
      tempo: tempo,
      # settings: settings, # if current_user is admin
    }
  end

  sig { returns(T::Boolean) }
  def api_enabled?
    # Main superagent always has API enabled
    return true if is_main_superagent?
    FeatureFlagService.superagent_enabled?(self, "api")
  end

  sig { returns(T::Boolean) }
  def trio_enabled?
    FeatureFlagService.superagent_enabled?(self, "trio")
  end

  sig { void }
  def enable_api!
    enable_feature_flag!("api")
  end

  # Check if a feature is enabled at the superagent level (with cascade from tenant/app)
  sig { params(flag_name: String).returns(T::Boolean) }
  def feature_enabled?(flag_name)
    FeatureFlagService.superagent_enabled?(self, flag_name)
  end

  sig { params(value: T.nilable(String)).void }
  def timezone=(value)
    if value.present?
      @timezone = ActiveSupport::TimeZone[value]
      self.settings = (self.settings || {}).merge('timezone' => T.must(@timezone).name)
    end
  end

  sig { returns(ActiveSupport::TimeZone) }
  def timezone
    @timezone ||= self.settings['timezone'] ? ActiveSupport::TimeZone[self.settings['timezone']] : ActiveSupport::TimeZone['UTC']
  end

  sig { params(time: T.any(Time, ActiveSupport::TimeWithZone)).returns(ActiveSupport::TimeWithZone) }
  def time_in_zone(time)
    time.in_time_zone(timezone.name)
  end

  sig { params(value: T.nilable(String)).void }
  def tempo=(value)
    if ['daily', 'weekly', 'monthly'].include?(value)
      set_defaults
      self.settings = self.settings.merge('tempo' => value)
    end
  end

  sig { returns(String) }
  def tempo
    self.settings['tempo'] || 'weekly'
  end

  sig { returns(T.nilable(String)) }
  def tempo_unit
    case tempo
    when 'daily'
      'day'
    when 'weekly'
      'week'
    when 'monthly'
      'month'
    when 'yearly'
      'year'
    end
  end

  sig { returns(T.nilable(String)) }
  def current_cycle_name
    case tempo
    when 'daily'
      'today'
    when 'weekly'
      'this-week'
    when 'monthly'
      'this-month'
    when 'yearly'
      'this-year'
    end
  end

  sig { returns(String) }
  def current_cycle_path
    "#{self.path}/cycles/#{current_cycle_name}"
  end

  sig { returns(T.nilable(String)) }
  def previous_cycle_name
    case tempo
    when 'daily'
      'yesterday'
    when 'weekly'
      'last-week'
    when 'monthly'
      'last-month'
    when 'yearly'
      'last-year'
    end
  end

  sig { returns(String) }
  def previous_cycle_path
    "#{self.path}/cycles/#{previous_cycle_name}"
  end

  sig { params(n: Integer).returns(ActiveSupport::TimeWithZone) }
  def n_cycles_ago(n)
    n.send(T.must(tempo_unit)).ago
  end

  sig { params(value: T.nilable(String)).void }
  def synchronization_mode=(value)
    if ['improv', 'orchestra'].include?(value)
      set_defaults
      self.settings = self.settings.merge('synchronization_mode' => value)
    end
  end

  sig { returns(String) }
  def synchronization_mode
    self.settings['synchronization_mode'] || 'improv'
  end

  sig { returns(T::Boolean) }
  def improv?
    self.synchronization_mode == 'improv'
  end

  sig { returns(T::Boolean) }
  def orchestra?
    self.synchronization_mode == 'orchestra'
  end

  sig { params(flag_name: String).void }
  def enable_feature!(flag_name)
    enable_feature_flag!(flag_name)
  end

  sig { params(flag_name: String).void }
  def disable_feature!(flag_name)
    disable_feature_flag!(flag_name)
  end

  sig { returns(Integer) }
  def file_storage_limit
    self.settings['file_storage_limit'] || 100.megabytes
  end

  sig { returns(String) }
  def file_storage_limit_in_human_size
    ActiveSupport::NumberHelper.number_to_human_size(file_storage_limit)
  end

  sig { returns(Integer) }
  def file_storage_usage
    @byte_sum ||= Attachment.where(superagent: self).sum(:byte_size)
  end

  sig { returns(String) }
  def file_storage_usage_in_human_size
    ActiveSupport::NumberHelper.number_to_human_size(file_storage_usage)
  end

  sig { returns(T::Boolean) }
  def within_file_upload_limit?
    file_storage_usage < file_storage_limit
  end

  sig { returns(T::Boolean) }
  def allow_file_uploads?
    file_attachments_enabled?
  end

  sig { returns(T::Boolean) }
  def file_attachments_enabled?
    # Use unified feature flag system with legacy fallback
    if feature_flags_hash.key?("file_attachments")
      FeatureFlagService.superagent_enabled?(self, "file_attachments")
    else
      # Legacy: check old setting location
      FeatureFlagService.tenant_enabled?(T.must(tenant), "file_attachments") &&
        settings["allow_file_uploads"].to_s == "true"
    end
  end

  sig { void }
  def handle_is_valid
    if handle.present?
      only_alphanumeric_with_dash = T.must(handle).match?(/\A[a-z0-9-]+\z/)
      errors.add(:handle, "must be alphanumeric with dashes") unless only_alphanumeric_with_dash
    else
      errors.add(:handle, "can't be blank")
    end
  end

  sig { void }
  def create_trustee!
    return if self.trustee_user
    trustee = User.create!(
      name: self.name,
      email: SecureRandom.uuid + '@not-a-real-email.com',
      user_type: 'trustee',
    )
    TenantUser.create!(
      tenant: tenant,
      user: trustee,
      display_name: trustee.name,
      handle: SecureRandom.hex(16),
    )
    self.trustee_user = trustee
    save!
  end

  sig { params(time_window: ActiveSupport::Duration).returns(ActiveRecord::Relation) }
  def recent_notes(time_window: 1.week)
    notes.where('created_at > ?', time_window.ago)
  end

  sig { returns(ActiveRecord::Relation) }
  def open_decisions
    decisions.where('deadline > ?', Time.current)
  end

  sig { returns(ActiveRecord::Relation) }
  def closed_decisions
    decisions.where('deadline < ?', Time.current)
  end

  sig { params(time_window: ActiveSupport::Duration).returns(ActiveRecord::Relation) }
  def recently_closed_decisions(time_window: 1.week)
    closed_decisions.where('deadline > ?', time_window.ago)
  end

  sig { returns(ActiveRecord::Relation) }
  def open_commitments
    commitments.where('deadline > ?', Time.current)
  end

  sig { returns(ActiveRecord::Relation) }
  def closed_commitments
    commitments.where('deadline < ?', Time.current)
  end

  sig { params(time_window: ActiveSupport::Duration).returns(ActiveRecord::Relation) }
  def recently_closed_commitments(time_window: 1.week)
    closed_commitments.where('deadline > ?', time_window.ago)
  end

  sig { returns(String) }
  def path_prefix
    "#{superagent_type}s"
  end

  sig { returns(T.nilable(String)) }
  def path
    if is_main_superagent?
      nil
    else
      "/#{path_prefix}/#{handle}"
    end
  end

  sig { returns(String) }
  def url
    if handle
      "#{T.must(tenant).url}#{path}"
    else
      T.must(tenant).url
    end
  end

  sig { returns(T.nilable(String)) }
  def truncated_id
    handle
  end

  sig { params(user: User, roles: T::Array[String]).returns(SuperagentMember) }
  def add_user!(user, roles: [])
    existing_sm = superagent_members.find_by(user: user)
    if existing_sm
      existing_sm.unarchive! if existing_sm.archived?
      existing_sm.add_roles!(roles)
      return existing_sm
    end
    sm = superagent_members.create!(
      tenant: tenant,
      user: user,
    )
    sm.add_roles!(roles)
    sm
  end

  sig { params(user: User).returns(T::Boolean) }
  def user_is_member?(user)
    superagent_members.where(user: user).count > 0
  end

  sig { params(limit: Integer).returns(T::Array[User]) }
  def team(limit: 100)
    superagent_members
      .where(archived_at: nil)
      .includes(:user)
      .limit(limit)
      .order(created_at: :desc).map do |sm|
        sm.user.superagent_member = sm
        sm.user
      end
  end

  sig { params(start_date: T.nilable(Time), end_date: T.nilable(Time), limit: Integer).returns(T.untyped) }
  def backlink_leaderboard(start_date: nil, end_date: nil, limit: 10)
    Link.backlink_leaderboard(superagent_id: self.id)
  end

  sig { returns(T.noreturn) }
  def delete!
    raise "Delete not implemented"
  end

  sig { params(created_by: User).returns(Invite) }
  def find_or_create_shareable_invite(created_by)
    invite = Invite.where(
      superagent: self,
      invited_user: nil,
    ).where('expires_at > ?', Time.current + 2.days).first
    if invite.nil?
      invite = Invite.create!(
        superagent: self,
        created_by: created_by,
        code: SecureRandom.hex(16),
        expires_at: 1.week.from_now,
      )
    end
    invite
  end

  sig { returns(T::Boolean) }
  def allow_invites?
    open_to_all = !self.settings['invite_only']
    all_members_can_invite = self.settings['all_members_can_invite']
    !!(open_to_all || all_members_can_invite)
  end

  sig { returns(T::Array[User]) }
  def representatives
    T.unsafe(superagent_members).where_has_role('representative').map(&:user)
  end

  sig { returns(T::Array[User]) }
  def admins
    T.unsafe(superagent_members).where_has_role('admin').map(&:user)
  end

  sig { returns(T::Boolean) }
  def all_members_can_invite?
    !!self.settings['all_members_can_invite']
  end

  sig { returns(T::Boolean) }
  def any_member_can_represent?
    !!self.settings['any_member_can_represent']
  end

  sig { returns(Cycle) }
  def current_cycle
    Cycle.new_from_superagent(self)
  end

end

# Constant alias for backwards compatibility (used in old migrations)
Studio = Superagent
