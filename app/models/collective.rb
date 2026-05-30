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
  belongs_to :identity_user, class_name: "User", optional: true
  belongs_to :trio_user, class_name: "User", optional: true
  before_validation :create_identity_user!
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

  scope :standard, -> { where(collective_type: "standard") }
  scope :private_workspaces, -> { where(collective_type: "private_workspace") }
  scope :chat, -> { where(collective_type: "chat") }
  scope :listable, -> { where(collective_type: "standard") }
  scope :billable_types, -> { where(collective_type: ["standard", "private_workspace"]) }

  VALID_COLLECTIVE_TYPES = ["standard", "private_workspace", "chat"].freeze

  validates :collective_type, inclusion: { in: VALID_COLLECTIVE_TYPES }
  validate :handle_is_valid
  validate :creator_is_not_collective_identity, on: :create
  validate :collective_type_immutable, on: :update

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
    Current.collective_id = collective.id
    Current.collective_handle = collective.handle
    collective
  end

  sig { void }
  def self.clear_thread_scope
    Current.collective_id = nil
    Current.collective_handle = nil
  end

  # Set thread-local collective context from a Collective instance.
  # Use this in jobs and other contexts where you have a Collective record.
  sig { params(collective: Collective).void }
  def self.set_thread_context(collective)
    Current.collective_id = collective.id
    Current.collective_handle = collective.handle
  end

  sig { returns(T.nilable(String)) }
  def self.current_handle
    Current.collective_handle
  end

  sig { returns(T.nilable(String)) }
  def self.current_id
    Current.collective_id
  end

  sig { params(handle: String).returns(T::Boolean) }
  def self.handle_available?(handle)
    return false if RESERVED_HANDLES.include?(handle)

    Collective.where(handle: handle).count == 0
  end

  sig { void }
  def set_defaults
    self.updated_by ||= created_by
    self.settings = {
      "unlisted" => true,
      "invite_only" => true,
      "timezone" => "UTC",
      "all_members_can_invite" => false,
      "any_member_can_represent" => false,
      "tempo" => "weekly",
      "synchronization_mode" => "improv",
      "allow_file_uploads" => false,
      "file_upload_limit" => 100.megabytes,
      "pinned" => {},
      "feature_flags" => {
        "api" => false,
        "file_attachments" => false,
      },
    }.merge(
      T.must(tenant).default_collective_settings
    ).merge(
      settings || {}
    )

    # Private workspaces enforce specific settings regardless of defaults
    if private_workspace?
      settings["unlisted"] = true
      settings["invite_only"] = true
      settings["all_members_can_invite"] = false
      settings["any_member_can_represent"] = false
      settings["tempo"] = "weekly"
    end

    # Chat collectives are hidden and locked down
    return unless chat?

    settings["unlisted"] = true
    settings["invite_only"] = true
    settings["all_members_can_invite"] = false
    settings["any_member_can_represent"] = false
  end

  sig { returns(T::Boolean) }
  def private_workspace?
    collective_type == "private_workspace"
  end

  sig { returns(T::Boolean) }
  def chat?
    collective_type == "chat"
  end

  sig { returns(T::Boolean) }
  def listable?
    collective_type == "standard"
  end

  sig { params(variant: T.nilable(Symbol)).returns(T.nilable(String)) }
  def image_path(variant: nil)
    if private_workspace?
      created_by&.image_url(variant: variant) || super
    else
      super
    end
  end

  sig { returns(T::Boolean) }
  def is_main_collective?
    T.must(tenant).main_collective_id == id
  end

  sig { void }
  def archive!
    update!(archived_at: Time.current)
    automation_rules.where(enabled: true).update_all(enabled: false)
  end

  sig { void }
  def unarchive!
    update!(archived_at: nil)
  end

  sig { returns(T::Boolean) }
  def archived?
    archived_at.present?
  end

  # === Free/paid tier predicates ===

  # Feature flags whose explicit enabling moves a collective to the paid tier.
  # Automations are also a paid trigger but tracked separately (as their own
  # resource, not a feature flag).
  PAID_FEATURE_FLAGS = T.let(%w[trio file_attachments].freeze, T::Array[String])

  # State of the collective: is it on the paid plan ($3/mo)?
  # Type-agnostic — applies equally to standard and private_workspace collectives.
  # Billing scope (which paid collectives actually count) is enforced separately
  # by Collective.billable_types in the count query.
  sig { returns(T::Boolean) }
  def paid_tier?
    return false if is_main_collective?
    return false if archived?
    return false if billing_exempt?

    automation_rules.enabled.exists? || trio_enabled? || file_attachments_enabled?
  end

  sig { returns(T::Boolean) }
  def free_tier?
    !paid_tier?
  end

  # True when the collective's owner has billing covered for paid features:
  # no billing required (feature disabled at tenant), platform-exempt admin,
  # or an active Stripe customer. This is what the controller gate checks
  # before allowing an action that would transition the collective into
  # paid_tier — `requires_stripe_billing?` can't be used at the gate because
  # at that moment paid_tier? still reads its pre-change state.
  #
  # Assumes `created_by` is a human user. If we ever allow AI agents to
  # create collectives, they'd need a billing path here (likely deferring
  # to a human parent or being explicitly billing_exempt at the collective
  # level).
  sig { returns(T::Boolean) }
  def owner_billing_setup?
    return true unless T.must(tenant).feature_enabled?("stripe_billing")

    owner = T.must(created_by)
    return true if owner.sys_admin? || owner.app_admin?

    owner.stripe_customer&.active? || false
  end

  # True when the collective is on the paid tier AND the owner hasn't
  # set up billing. Used for app-level redirects and `/billing` inventory.
  sig { returns(T::Boolean) }
  def requires_stripe_billing?
    paid_tier? && !owner_billing_setup?
  end

  # Hypothetical paid_tier? state after a pending action. Each caller passes
  # only what it's changing; defaults read from the current DB state. Used
  # by the controller gate to detect free→paid transitions before save.
  #
  # Override values for trio/file_attachments are AND'd with the tenant
  # cascade — setting a flag locally has no billing effect if the tenant
  # doesn't enable it (post-save trio_enabled? / file_attachments_enabled?
  # would still return false via the cascade). Default (nil) reads from
  # existing predicates which already respect cascade.
  sig do
    params(
      has_enabled_automation_after: T.nilable(T::Boolean),
      trio_after: T.nilable(T::Boolean),
      file_attachments_after: T.nilable(T::Boolean)
    ).returns(T::Boolean)
  end
  def would_be_paid_tier?(has_enabled_automation_after: nil, trio_after: nil, file_attachments_after: nil)
    return false if is_main_collective?
    return false if archived?
    return false if billing_exempt?

    t = T.must(tenant)
    automation = has_enabled_automation_after.nil? ? automation_rules.enabled.exists? : has_enabled_automation_after
    # Match the cascade used by Collective#trio_enabled? and
    # Collective#file_attachments_enabled?: FeatureFlagService.tenant_enabled? for
    # both (NOT Tenant#trio_enabled? / Tenant#file_attachments_enabled?, which apply
    # additional legacy fallbacks at the tenant level that the collective cascade
    # doesn't consult — an existing inconsistency in the codebase we're preserving).
    trio = trio_after.nil? ? trio_enabled? : (trio_after && FeatureFlagService.tenant_enabled?(t, "trio"))
    files = file_attachments_after.nil? ? file_attachments_enabled? : (file_attachments_after && FeatureFlagService.tenant_enabled?(t, "file_attachments"))

    automation || trio || files
  end

  sig { void }
  def creator_is_not_collective_identity
    errors.add(:created_by, "cannot be a collective identity") if created_by&.collective_identity?
  end

  sig { void }
  def collective_type_immutable
    errors.add(:collective_type, "cannot be changed") if collective_type_changed?
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
    @byte_sum ||= Attachment.where(collective: self).sum(:byte_size) +
                  MediaItem.where(collective: self).sum(:byte_size)
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

  RESERVED_HANDLES = ["main"].freeze

  sig { void }
  def handle_is_valid
    if handle.present?
      only_alphanumeric_with_dash = T.must(handle).match?(/\A[a-z0-9-]+\z/)
      errors.add(:handle, "must be alphanumeric with dashes") unless only_alphanumeric_with_dash
      errors.add(:handle, "is reserved") if RESERVED_HANDLES.include?(handle)
    else
      errors.add(:handle, "can't be blank")
    end
  end

  sig { void }
  def create_identity_user!
    return if private_workspace?
    return if chat?
    return if identity_user

    identity = User.create!(
      name: name,
      email: SecureRandom.uuid + "@not-a-real-email.com",
      user_type: "collective_identity"
    )
    TenantUser.create!(
      tenant: tenant,
      user: identity,
      display_name: identity.name,
      handle: SecureRandom.hex(16)
    )
    self.identity_user = identity
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
    private_workspace? ? "workspace" : "collectives"
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
    # Workspaces are private to their owner — but the trio system agent is
    # added by the owner opt-in flow (TrioSeeder), not as a normal member.
    raise "Cannot add other users to a private workspace" if private_workspace? && user != created_by && !user.system?

    if chat? && collective_members.where(archived_at: nil).count >= 2 && !collective_members.exists?(user: user)
      raise "Chat collectives are limited to two members"
    end

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
  # - Being the collective's own identity user
  #
  # TrusteeGrants do NOT give direct access - they only work during
  # active representation sessions (handled elsewhere in controller/session logic).
  sig { params(user: User).returns(T::Boolean) }
  def accessible_by?(user)
    # Direct membership check
    return true if user_is_member?(user)

    # Collective identity user accessing their own collective
    return user.identity_collective == self if user.collective_identity? && user.identity_collective.present?

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
    raise "Cannot create invites for the main collective" if is_main_collective?
    raise "Cannot create invites for private workspaces" if private_workspace?
    raise "Cannot create invites for chat collectives" if chat?

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
