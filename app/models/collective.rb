# typed: true

class Collective < ApplicationRecord
  extend T::Sig

  include CanPin
  include HasImage
  include HasFeatureFlags
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :created_by, class_name: "User"
  belongs_to :updated_by, class_name: "User"
  belongs_to :proxy_user, class_name: "User"
  before_validation :create_proxy_user!
  before_create :set_defaults
  tables = ActiveRecord::Base.connection.tables - [
    "tenants", "users", "tenant_users",
    "collectives", "api_tokens", "oauth_identities",
    # Rails internal tables
    "ar_internal_metadata", "schema_migrations",
    "active_storage_attachments", "active_storage_blobs",
    "active_storage_variant_records",
  ]
  tables.each do |table|
    has_many table.to_sym
  end
  has_many :users, through: :collective_members
  validates :collective_type, inclusion: { in: ["studio", "scene"] }
  validate :handle_is_valid
  validate :creator_is_not_collective_proxy, on: :create

  # NOTE: This is commented out because there is a bug where
  # the corresponding note history event is not created
  # when the note itself is created within a callback.
  # So we rely on the controller to create the welcome note.
  # after_create :create_welcome_note!

  sig { params(subdomain: String, handle: T.nilable(String)).returns(Collective) }
  def self.scope_thread_to_collective(subdomain:, handle:)
    # In single-tenant mode, treat empty/blank subdomain as PRIMARY_SUBDOMAIN
    subdomain = Tenant.single_tenant_subdomain.to_s if Tenant.single_tenant_mode? && subdomain.blank?

    tenant = Tenant.scope_thread_to_tenant(subdomain: subdomain)
    collective = handle ? tenant.collectives.find_by!(handle: handle) : tenant.main_collective
    if collective.nil? && subdomain == ENV["AUTH_SUBDOMAIN"]
      # This is a special case for the auth subdomain.
      # We only need a temporary collective object to set the thread scope.
      # It will not be persisted to the database.
      collective = Collective.new(
        id: SecureRandom.uuid,
        name: "Harmonic",
        handle: SecureRandom.hex(16),
        tenant: tenant
      )
      tenant.main_collective = collective
    elsif collective.nil? && tenant.main_collective.nil?
      raise ActiveRecord::RecordNotFound, "Tenant with subdomain '#{subdomain}' is missing a main collective"
    elsif collective.nil?
      raise ActiveRecord::RecordNotFound, "Collective with handle '#{handle}' not found"
    end
    Thread.current[:collective_id] = collective.id
    Thread.current[:collective_handle] = collective.handle
    collective
  end

  sig { void }
  def self.clear_thread_scope
    Thread.current[:collective_id] = nil
    Thread.current[:collective_handle] = nil
  end

  # Set thread-local collective context from a Collective instance.
  # Use this in jobs and other contexts where you have a Collective record.
  sig { params(collective: Collective).void }
  def self.set_thread_context(collective)
    Thread.current[:collective_id] = collective.id
    Thread.current[:collective_handle] = collective.handle
  end

  sig { returns(T.nilable(String)) }
  def self.current_handle
    Thread.current[:collective_handle]
  end

  sig { returns(T.nilable(String)) }
  def self.current_id
    Thread.current[:collective_id]
  end

  sig { params(handle: String).returns(T::Boolean) }
  def self.handle_available?(handle)
    Collective.where(handle: handle).count == 0
  end

  sig { void }
  def set_defaults
    self.updated_by ||= created_by
    self.settings = {
      unlisted: true,
      invite_only: true,
      timezone: "UTC",
      all_members_can_invite: false,
      any_member_can_represent: false,
      tempo: "weekly",
      synchronization_mode: "improv",
      allow_file_uploads: true,
      file_upload_limit: 100.megabytes,
      pinned: {},
      feature_flags: {
        api: false,
      },
    }.merge(
      T.must(tenant).default_studio_settings
    ).merge(
      settings || {}
    )
  end

  sig { returns(T::Boolean) }
  def is_main_collective?
    T.must(tenant).main_collective_id == id
  end

  sig { returns(T::Boolean) }
  def is_scene?
    collective_type == "scene"
  end

  sig { params(value: T::Boolean).void }
  def open_scene=(value)
    if [true, false].include?(value)
      self.settings = (settings || {}).merge("open_scene" => value)
    else
      errors.add(:settings, "'open_scene' must be a boolean")
    end
  end

  sig { returns(T::Boolean) }
  def scene_is_open?
    # An open scene is a scene that does not require an invite to join
    is_scene? && settings["open_scene"] == true
  end

  sig { returns(T::Boolean) }
  def scene_is_invite_only?
    is_scene? && !scene_is_open?
  end

  sig { void }
  def creator_is_not_collective_proxy
    errors.add(:created_by, "cannot be a collective proxy") if created_by&.collective_proxy?
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
    # Main collective always has API enabled
    return true if is_main_collective?

    FeatureFlagService.collective_enabled?(self, "api")
  end

  sig { returns(T::Boolean) }
  def trio_enabled?
    FeatureFlagService.collective_enabled?(self, "trio")
  end

  sig { void }
  def enable_api!
    enable_feature_flag!("api")
  end

  # Check if a feature is enabled at the collective level (with cascade from tenant/app)
  sig { params(flag_name: String).returns(T::Boolean) }
  def feature_enabled?(flag_name)
    FeatureFlagService.collective_enabled?(self, flag_name)
  end

  sig { params(value: T.nilable(String)).void }
  def timezone=(value)
    return unless value.present?

    @timezone = ActiveSupport::TimeZone[value]
    self.settings = (settings || {}).merge("timezone" => T.must(@timezone).name)
  end

  sig { returns(ActiveSupport::TimeZone) }
  def timezone
    @timezone ||= settings["timezone"] ? ActiveSupport::TimeZone[settings["timezone"]] : ActiveSupport::TimeZone["UTC"]
  end

  sig { params(time: T.any(Time, ActiveSupport::TimeWithZone)).returns(ActiveSupport::TimeWithZone) }
  def time_in_zone(time)
    time.in_time_zone(timezone.name)
  end

  sig { params(value: T.nilable(String)).void }
  def tempo=(value)
    return unless ["daily", "weekly", "monthly"].include?(value)

    set_defaults
    self.settings = settings.merge("tempo" => value)
  end

  sig { returns(String) }
  def tempo
    settings["tempo"] || "weekly"
  end

  sig { returns(T.nilable(String)) }
  def tempo_unit
    case tempo
    when "daily"
      "day"
    when "weekly"
      "week"
    when "monthly"
      "month"
    when "yearly"
      "year"
    end
  end

  sig { returns(T.nilable(String)) }
  def current_cycle_name
    case tempo
    when "daily"
      "today"
    when "weekly"
      "this-week"
    when "monthly"
      "this-month"
    when "yearly"
      "this-year"
    end
  end

  sig { returns(String) }
  def current_cycle_path
    "#{path}/cycles/#{current_cycle_name}"
  end

  sig { returns(T.nilable(String)) }
  def previous_cycle_name
    case tempo
    when "daily"
      "yesterday"
    when "weekly"
      "last-week"
    when "monthly"
      "last-month"
    when "yearly"
      "last-year"
    end
  end

  sig { returns(String) }
  def previous_cycle_path
    "#{path}/cycles/#{previous_cycle_name}"
  end

  sig { params(n: Integer).returns(ActiveSupport::TimeWithZone) }
  def n_cycles_ago(n)
    n.send(T.must(tempo_unit)).ago
  end

  sig { params(value: T.nilable(String)).void }
  def synchronization_mode=(value)
    return unless ["improv", "orchestra"].include?(value)

    set_defaults
    self.settings = settings.merge("synchronization_mode" => value)
  end

  sig { returns(String) }
  def synchronization_mode
    settings["synchronization_mode"] || "improv"
  end

  sig { returns(T::Boolean) }
  def improv?
    synchronization_mode == "improv"
  end

  sig { returns(T::Boolean) }
  def orchestra?
    synchronization_mode == "orchestra"
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
    settings["file_storage_limit"] || 100.megabytes
  end

  sig { returns(String) }
  def file_storage_limit_in_human_size
    ActiveSupport::NumberHelper.number_to_human_size(file_storage_limit)
  end

  sig { returns(Integer) }
  def file_storage_usage
    @byte_sum ||= Attachment.where(collective: self).sum(:byte_size)
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
      FeatureFlagService.collective_enabled?(self, "file_attachments")
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
  def create_proxy_user!
    return if proxy_user

    proxy = User.create!(
      name: name,
      email: SecureRandom.uuid + "@not-a-real-email.com",
      user_type: "collective_proxy"
    )
    TenantUser.create!(
      tenant: tenant,
      user: proxy,
      display_name: proxy.name,
      handle: SecureRandom.hex(16)
    )
    self.proxy_user = proxy
    save!
  end

  sig { params(time_window: ActiveSupport::Duration).returns(ActiveRecord::Relation) }
  def recent_notes(time_window: 1.week)
    notes.where("created_at > ?", time_window.ago)
  end

  sig { returns(ActiveRecord::Relation) }
  def open_decisions
    decisions.where("deadline > ?", Time.current)
  end

  sig { returns(ActiveRecord::Relation) }
  def closed_decisions
    decisions.where("deadline < ?", Time.current)
  end

  sig { params(time_window: ActiveSupport::Duration).returns(ActiveRecord::Relation) }
  def recently_closed_decisions(time_window: 1.week)
    closed_decisions.where("deadline > ?", time_window.ago)
  end

  sig { returns(ActiveRecord::Relation) }
  def open_commitments
    commitments.where("deadline > ?", Time.current)
  end

  sig { returns(ActiveRecord::Relation) }
  def closed_commitments
    commitments.where("deadline < ?", Time.current)
  end

  sig { params(time_window: ActiveSupport::Duration).returns(ActiveRecord::Relation) }
  def recently_closed_commitments(time_window: 1.week)
    closed_commitments.where("deadline > ?", time_window.ago)
  end

  sig { returns(String) }
  def path_prefix
    "#{collective_type}s"
  end

  sig { returns(T.nilable(String)) }
  def path
    if is_main_collective?
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

  sig { params(user: User, roles: T::Array[String]).returns(CollectiveMember) }
  def add_user!(user, roles: [])
    existing_cm = collective_members.find_by(user: user)
    if existing_cm
      existing_cm.unarchive! if existing_cm.archived?
      existing_cm.add_roles!(roles)
      return existing_cm
    end
    cm = collective_members.create!(
      tenant: tenant,
      user: user
    )
    cm.add_roles!(roles)
    cm
  end

  sig { params(user: User).returns(T::Boolean) }
  def user_is_member?(user)
    collective_members.where(user: user).count > 0
  end

  # Check if a user can access this collective.
  # Access requires either:
  # - Direct membership, OR
  # - Being the collective's own proxy user
  #
  # TrusteeGrants do NOT give direct access - they only work during
  # active representation sessions (handled elsewhere in controller/session logic).
  sig { params(user: User).returns(T::Boolean) }
  def accessible_by?(user)
    # Direct membership check
    return true if user_is_member?(user)

    # Collective proxy accessing their own collective
    if user.collective_proxy? && user.proxy_collective.present?
      return user.proxy_collective == self
    end

    false
  end

  sig { params(limit: Integer).returns(T::Array[User]) }
  def team(limit: 100)
    collective_members
      .where(archived_at: nil)
      .includes(:user)
      .limit(limit)
      .order(created_at: :desc).map do |cm|
        cm.user.collective_member = cm
        cm.user
      end
  end

  sig { params(start_date: T.nilable(Time), end_date: T.nilable(Time), limit: Integer).returns(T.untyped) }
  def backlink_leaderboard(start_date: nil, end_date: nil, limit: 10)
    Link.backlink_leaderboard(collective_id: id)
  end

  sig { returns(T.noreturn) }
  def delete!
    raise "Delete not implemented"
  end

  sig { params(created_by: User).returns(Invite) }
  def find_or_create_shareable_invite(created_by)
    invite = Invite.where(
      collective: self,
      invited_user: nil
    ).where("expires_at > ?", 2.days.from_now).first
    if invite.nil?
      invite = Invite.create!(
        collective: self,
        created_by: created_by,
        code: SecureRandom.hex(16),
        expires_at: 1.week.from_now
      )
    end
    invite
  end

  sig { returns(T::Boolean) }
  def allow_invites?
    open_to_all = !settings["invite_only"]
    all_members_can_invite = settings["all_members_can_invite"]
    !!(open_to_all || all_members_can_invite)
  end

  sig { returns(T::Array[User]) }
  def representatives
    T.unsafe(collective_members).where_has_role("representative").map(&:user)
  end

  sig { returns(T::Array[User]) }
  def admins
    T.unsafe(collective_members).where_has_role("admin").map(&:user)
  end

  sig { returns(T::Boolean) }
  def all_members_can_invite?
    !!settings["all_members_can_invite"]
  end

  sig { returns(T::Boolean) }
  def any_member_can_represent?
    !!settings["any_member_can_represent"]
  end

  sig { returns(Cycle) }
  def current_cycle
    Cycle.new_from_collective(self)
  end
end
