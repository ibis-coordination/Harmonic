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
  after_update :sync_identity_user_handle!, if: :saved_change_to_handle?
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
  has_one :funding_pool, dependent: :destroy

  scope :standard, -> { where(collective_type: "standard") }
  scope :private_workspaces, -> { where(collective_type: "private_workspace") }
  scope :chat, -> { where(collective_type: "chat") }
  scope :agent_funding, -> { where(collective_type: "agent_funding") }
  scope :listable, -> { where(collective_type: "standard") }
  scope :billable_types, -> { where(collective_type: ["standard", "private_workspace"]) }

  # Adds a boolean `has_heartbeat` attribute to each row: true when `user` has
  # a live (non-expired) heartbeat on that collective this cycle. Single source
  # for the heart indicators on both /collectives and the places sheet. Uses an
  # EXISTS subquery rather than a LEFT JOIN so it never multiplies rows — the
  # places sheet renders on every page, so a duplicated collective would be
  # pervasive. `has_heartbeat` is orderable (e.g. `.order(:has_heartbeat, :name)`).
  scope :with_heartbeat_for, ->(user) {
    select(sanitize_sql_array([
      "collectives.*, EXISTS(SELECT 1 FROM heartbeats WHERE heartbeats.collective_id = collectives.id " \
      "AND heartbeats.user_id = ? AND heartbeats.expires_at > ?) AS has_heartbeat",
      user.id, Time.current
    ]))
  }

  # The `has_heartbeat` boolean is only present on rows loaded via
  # `with_heartbeat_for`. Default to false elsewhere so views (the /collectives
  # list, the places sheet) can call it unconditionally without blowing up on a
  # plainly-loaded record.
  sig { returns(T::Boolean) }
  def has_heartbeat
    read_attribute(:has_heartbeat) ? true : false
  end

  # agent_funding: joining IS consenting to fund the collective's agents' LLM
  # usage from your own prepaid balance (each member pays Stripe directly per
  # call — the collective never holds funds). Unlisted, invite-only, not
  # billable; see LLMGateway::PayerResolver for the payer draw.
  VALID_COLLECTIVE_TYPES = ["standard", "private_workspace", "chat", "agent_funding"].freeze

  validates :collective_type, inclusion: { in: VALID_COLLECTIVE_TYPES }
  # Per-UTC-day ceiling on how much this funding collective may draw from any
  # single member, enforced per call in LLMGateway::PayerResolver.
  validates :member_daily_draw_cap_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :member_daily_draw_cap_funding_only, if: :member_daily_draw_cap_cents_changed?
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
    return false if ReservedHandles.forbidden_for_collective?(handle)

    # Collective and user handles share one per-tenant namespace (Goal 2 of
    # handle-model-unification): creating a collective also seeds an identity
    # user that claims the collective's handle. Treat a handle as available only
    # when neither a collective nor a user already holds it, so the new
    # collective's identity user can take the identical handle instead of a
    # suffixed fallback (@foo-team ↔ /collectives/foo-team stay in sync). Both
    # columns are citext, so the lookups are case-insensitive: "Foo" is taken
    # once "foo" exists.
    !Collective.where(handle: handle).exists? && !TenantUser.where(handle: handle).exists?
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
      "any_member_can_summarize" => false,
      "tempo" => "weekly",
      "synchronization_mode" => "improv",
      "allow_file_uploads" => false,
      "file_upload_limit" => 100.megabytes,
      "pinned" => {},
      "feature_flags" => {
        "api" => true,
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
      settings["any_member_can_summarize"] = false
      settings["tempo"] = "weekly"
    end

    # Chat collectives are hidden and locked down
    return unless chat?

    settings["unlisted"] = true
    settings["invite_only"] = true
    settings["all_members_can_invite"] = false
    settings["any_member_can_represent"] = false
    settings["any_member_can_summarize"] = false
  end

  sig { returns(T::Boolean) }
  def standard?
    collective_type == "standard"
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
  def agent_funding?
    collective_type == "agent_funding"
  end

  sig { void }
  def member_daily_draw_cap_funding_only
    return if member_daily_draw_cap_cents.nil? || agent_funding?

    errors.add(:member_daily_draw_cap_cents, "can only be set on agent funding collectives")
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

  # Archive a collective. Owner-only (raises NotOwner if actor != created_by).
  # No-op when already archived — second-archive must NOT clobber the original
  # archived_at / archived_by_id, since those are the audit trail.
  #
  # On the happy path: auto-downgrades paid → free so a future unarchive can
  # never silently resume billing, then writes archived_at + archived_by_id,
  # then disables any remaining enabled automation rules.
  #
  # Invariant: archived_by_id IS NOT NULL iff archived_at IS NOT NULL. The
  # FK uses ON DELETE RESTRICT — a user can't be hard-deleted while they're
  # the archiver of any collective. Today user "deletion" is a PII scrub
  # that leaves the row in place, so this restriction never fires in
  # practice — it's a guardrail for any future hard-delete path.
  sig { params(actor: User).returns(T.nilable(StripeService::SyncResult)) }
  def archive!(actor:)
    raise NotOwner unless actor == T.must(created_by)
    return nil if archived?

    transaction do
      downgrade!(actor: actor)
      update!(archived_at: Time.current, archived_by_id: actor.id)
      automation_rules.where(enabled: true).update_all(enabled: false)
    end
    sync_owner_subscription_quantity!
  end

  sig { params(actor: User).returns(T.nilable(StripeService::SyncResult)) }
  def unarchive!(actor:)
    raise NotOwner unless actor == T.must(created_by)
    return nil unless archived?

    update!(archived_at: nil, archived_by_id: nil)
    sync_owner_subscription_quantity!
  end

  sig { returns(T::Boolean) }
  def archived?
    archived_at.present?
  end

  # === Free/paid tier state machine ===

  # Feature flags that require the paid tier to take effect at the collective
  # level. Automations are also a paid trigger but tracked separately (as
  # their own resource, not a feature flag). `downgrade!` clears these flags.
  PAID_FEATURE_FLAGS = T.let(%w[trio file_attachments].freeze, T::Array[String])

  TIER_FREE = "free"
  TIER_PAID = "paid"
  TIER_LAPSED = "lapsed"
  TIERS = T.let([TIER_FREE, TIER_PAID, TIER_LAPSED].freeze, T::Array[String])

  # Allowed tier transitions. Anything not in this map is rejected by the
  # `tier_transition_allowed` validation.
  VALID_TIER_TRANSITIONS = T.let({
    TIER_FREE => [TIER_PAID].freeze,
    TIER_PAID => [TIER_FREE, TIER_LAPSED].freeze,
    TIER_LAPSED => [TIER_PAID, TIER_FREE].freeze,
  }.freeze, T::Hash[String, T::Array[String]])

  validates :tier, inclusion: { in: TIERS }
  validate :tier_transition_allowed

  # Raised by `upgrade!` when the actor has no active Stripe customer; the
  # controller catches this and redirects to Stripe Checkout.
  class BillingRequired < StandardError; end

  # Raised by `upgrade!` / `downgrade!` when the actor is not the collective's
  # creator. Owner transfer is a separate (future) feature.
  class NotOwner < StandardError; end

  # Shared error message used by controller gates that refuse paid-feature
  # actions on free collectives (automation create/update/toggle, file
  # uploads via API, etc.).
  PAID_FEATURE_ERROR = "This action requires the paid plan. Upgrade on the collective settings page."

  # True when this collective is on the paid plan. Column-driven; transitions
  # only happen via the explicit `upgrade!` / `confirm_upgrade!` / `downgrade!`
  # / `mark_lapsed!` / `restore_from_lapsed!` methods. Main collectives stay at
  # TIER_FREE; per-feature runtime gates short-circuit on `is_main_collective?`.
  sig { returns(T::Boolean) }
  def paid_tier?
    tier == TIER_PAID
  end

  sig { returns(T::Boolean) }
  def free_tier?
    !paid_tier?
  end

  # True when this collective is on the lapsed state — paid features are
  # paused pending the owner restoring their Stripe subscription. Used by
  # `/billing` inventory to surface a "Resume billing" affordance.
  sig { returns(T::Boolean) }
  def requires_stripe_billing?
    tier == TIER_LAPSED
  end

  # Begin upgrading this collective. If billing doesn't need to be set up
  # (collective is billing_exempt, the tenant has no stripe_billing flag,
  # the actor is a sys/app admin, or the actor already has an active Stripe
  # customer), the upgrade is confirmed inline. Otherwise `BillingRequired`
  # is raised so the controller can redirect to Stripe Checkout — final
  # confirmation then comes via `confirm_upgrade!` from the
  # checkout.session.completed webhook.
  sig { params(actor: User).void }
  def upgrade!(actor:)
    raise NotOwner unless actor == T.must(created_by)
    # Main collectives are always feature-unlocked via the is_main_collective?
    # short-circuit and never billed — no-op rather than letting a direct POST
    # to /collectives/<main_handle>/upgrade charge the owner unnecessarily.
    return if is_main_collective?
    return if paid_tier?

    raise BillingRequired unless billing_covered_for_upgrade?(actor)

    update!(tier: TIER_PAID)
  end

  # Webhook entry point: flips free→paid (or lapsed→paid) after Stripe
  # Checkout completes. The lapsed→paid path covers a user who let their
  # subscription cancel and then upgraded a collective via the standard
  # flow — the checkout creates a new subscription, which also auto-restores
  # any other lapsed collectives via `restore_lapsed_collectives_for`.
  #
  # SECURITY: this performs NO authorization and NO billing-active check —
  # it trusts the caller to have verified both. Only call it from a
  # signature-verified Stripe webhook, or from a path that has already
  # confirmed the actor owns the collective AND that billing is set up
  # (see CollectivesController#upgrade, which gates via `upgrade!`). Never
  # wire it to user-facing input directly.
  sig { void }
  def confirm_upgrade!
    return if paid_tier?

    update!(tier: TIER_PAID)
  end

  # Owner-initiated downgrade. Actively disables paid features (disables
  # enabled automations, clears trio + file_attachments flags, deactivates
  # the trio agent) — the user opted out, so we leave a clean slate for any
  # future re-upgrade rather than preserving state.
  sig { params(actor: User).void }
  def downgrade!(actor:)
    raise NotOwner unless actor == T.must(created_by)
    # Main collectives are never on the paid tier — symmetric guard with upgrade!.
    return if is_main_collective?
    return if tier == TIER_FREE

    transaction do
      automation_rules.enabled.update_all(enabled: false)
      PAID_FEATURE_FLAGS.each { |flag| disable_feature_flag!(flag) }
      TrioActivator.deactivate!(self) if trio_user_id.present?
      update!(tier: TIER_FREE)
    end
  end

  # Webhook entry point: flips paid→lapsed when the owner's Stripe
  # subscription deletes or a payment fails. Runtime gates short-circuit on
  # `paid_tier?` so feature access pauses without touching configuration —
  # restore is instant and zero-loss.
  sig { void }
  def mark_lapsed!
    return if requires_stripe_billing?
    return unless paid_tier?

    update!(tier: TIER_LAPSED)
  end

  # Webhook entry point: flips lapsed→paid when a new subscription is
  # created (e.g., owner updated their card). No restoration step needed —
  # `mark_lapsed!` never touched feature config.
  sig { void }
  def restore_from_lapsed!
    return unless requires_stripe_billing?

    update!(tier: TIER_PAID)
  end

  sig { void }
  def tier_transition_allowed
    return unless tier_changed?
    return if new_record?

    previous = T.must(tier_was)
    allowed = VALID_TIER_TRANSITIONS[previous] || []
    return if allowed.include?(tier)

    errors.add(:tier, "invalid transition from #{previous.inspect} to #{tier.inspect}")
  end

  sig { params(actor: User).returns(T::Boolean) }
  private def billing_covered_for_upgrade?(actor)
    return true if billing_exempt?
    return true unless T.must(tenant).feature_enabled?("stripe_billing")
    return true if actor.sys_admin? || actor.app_admin?

    actor.stripe_customer&.active? || false
  end

  # Keep the billable owner's Stripe subscription quantity in sync with the
  # collective's contribution to `billable_quantity`. archive!/unarchive! call
  # this so any caller (controller, model cascade, console) gets the right
  # billing side-effect without having to remember. No-op on tenants without
  # stripe_billing and idempotent on Stripe's side when the quantity is unchanged.
  sig { returns(T.nilable(StripeService::SyncResult)) }
  private def sync_owner_subscription_quantity!
    return nil unless T.must(tenant).feature_enabled?("stripe_billing")
    owner = created_by
    return nil unless owner

    StripeService.sync_subscription_quantity!(owner)
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
    return false unless tier_unlocks_paid_features?

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
    return false unless tier_unlocks_paid_features?

    # Use unified feature flag system with legacy fallback
    if feature_flags_hash.key?("file_attachments")
      FeatureFlagService.collective_enabled?(self, "file_attachments")
    else
      # Legacy: check old setting location
      FeatureFlagService.tenant_enabled?(T.must(tenant), "file_attachments") &&
        settings["allow_file_uploads"].to_s == "true"
    end
  end

  # True when the collective should have paid features available, regardless
  # of why: it's on the paid tier, it's the main collective (special-cased
  # to always have features), or the tenant doesn't have stripe_billing
  # enabled at all (self-hosted instances have no tier model and all
  # features should just work).
  sig { returns(T::Boolean) }
  def tier_unlocks_paid_features?
    return true if is_main_collective?
    return true unless T.must(tenant).feature_enabled?("stripe_billing")

    paid_tier?
  end

  sig { void }
  def handle_is_valid
    if handle.present?
      # Uppercase is allowed so the display form keeps the case the user chose
      # ("Foo-Team"). The `handle` column is `citext`, so lookup and the
      # (tenant_id, handle) uniqueness index stay case-insensitive.
      only_alphanumeric_with_dash = T.must(handle).match?(/\A[a-zA-Z0-9-]+\z/)
      errors.add(:handle, "must be alphanumeric with dashes") unless only_alphanumeric_with_dash
      errors.add(:handle, "is reserved") if ReservedHandles.forbidden_for_collective?(handle)
    else
      errors.add(:handle, "can't be blank")
    end
  end

  sig { void }
  def create_identity_user!
    return if private_workspace?
    return if chat?
    return if agent_funding? # funding collectives don't act or speak
    return if identity_user
    # The identity shares the collective's handle; without one there's nothing
    # to share, so defer to `handle_is_valid` to surface the blank-handle error
    # rather than minting an orphan identity user with a placeholder handle.
    return if handle.blank?

    identity = User.create!(
      name: name,
      email: SecureRandom.uuid + "@not-a-real-email.com",
      user_type: "collective_identity"
    )
    TenantUser.create!(
      tenant: tenant,
      user: identity,
      display_name: identity.name,
      handle: TenantUser.identity_handle_for(tenant_id: T.must(tenant).id, base: T.must(handle))
    )
    self.identity_user = identity
    save!

    # Make the identity a first-class member of the tenant's main collective, so
    # it's counted in the directory and admissible to the tenant-wide "everyone"
    # list on the general membership path — no special-case exception needed
    # (issue #477). The main collective has no parent to join, and during its own
    # creation `tenant.main_collective` isn't wired up yet, so skip both cases:
    # only join when a main collective exists and it isn't this collective.
    main = T.must(tenant).main_collective
    main.add_user!(identity) if main && main.id != id
  end

  # Keep the identity user's handle in lockstep when the collective is renamed,
  # so `@new-handle` keeps resolving to the same identity. Suffixes on collision
  # exactly like creation (excluding the identity's own row from the check).
  sig { void }
  def sync_identity_user_handle!
    return unless identity_user
    return if handle.blank?

    tenant_user = TenantUser.tenant_scoped_only(T.must(tenant_id)).find_by(user_id: identity_user_id)
    return unless tenant_user

    desired = TenantUser.identity_handle_for(
      tenant_id: T.must(tenant_id),
      base: T.must(handle),
      except_user_id: identity_user_id,
    )
    tenant_user.update!(handle: desired) unless tenant_user.handle.to_s.casecmp?(desired)
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

  # True when `user` is this collective's own identity user — the actor behind
  # collective automations and collective representation, which acts as a
  # member/admin of its own collective.
  sig { params(user: T.nilable(User)).returns(T::Boolean) }
  def identity_user?(user)
    !user.nil? && identity_user_id == user.id
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

  sig { returns(Integer) }
  def member_count
    collective_members.where(archived_at: nil).count
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
    # Funding membership is a consent to spend money; every invite names its
    # invitee rather than circulating as an open link.
    raise "Cannot create shareable invites for agent funding collectives" if agent_funding?

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

  # Members holding `role` (e.g. "admin", "representative", "summarizer").
  # Backs the role group tags (@admins/@representatives/… — see
  # MentionParser.resolve_collective_local), which are derived from the role
  # list so this stays the single lookup for any current or future role.
  sig { params(role: String).returns(T::Array[User]) }
  def users_with_role(role)
    T.unsafe(collective_members).where_has_role(role).map(&:user)
  end

  sig { returns(T::Array[User]) }
  def representatives
    users_with_role("representative")
  end

  sig { returns(T::Array[User]) }
  def admins
    users_with_role("admin")
  end

  # True when `user` holds the admin role in this collective. Gates the
  # @everyone mention (admin-only); see MentionParser.resolve_collective_local.
  sig { params(user: T.nilable(User)).returns(T::Boolean) }
  def admin?(user)
    return false if user.nil?

    T.unsafe(collective_members).where_has_role("admin").exists?(user_id: user.id)
  end

  # Every current (non-archived) member's user. Unlike #team this is uncapped —
  # it backs the @everyone fan-out, which must reach the whole collective.
  sig { returns(T::Array[User]) }
  def member_users
    collective_members
      .where(archived_at: nil)
      .includes(:user)
      .map(&:user)
  end

  sig { returns(T::Boolean) }
  def all_members_can_invite?
    !!settings["all_members_can_invite"]
  end

  sig { returns(T::Boolean) }
  def any_member_can_represent?
    !!settings["any_member_can_represent"]
  end

  sig { returns(T::Boolean) }
  def any_member_can_summarize?
    !!settings["any_member_can_summarize"]
  end

  sig { returns(Cycle) }
  def current_cycle
    Cycle.new_from_collective(self)
  end
end
