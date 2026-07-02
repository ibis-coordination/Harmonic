# typed: true

class TenantUser < ApplicationRecord
  extend T::Sig

  include CanPin
  include HasRoles
  include HasDismissibleNotices
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :user
  before_create :set_defaults

  # Handles claimable only by a system agent with the matching system_role.
  # Currently: "trio" is reserved for the trio system agent (only the main
  # collective's trio actually claims it; other per-collective trios use
  # random hex handles to avoid the tenant-wide uniqueness collision).
  RESERVED_HANDLES = T.let({ "trio" => "trio" }.freeze, T::Hash[String, String])

  BIO_MAX_LENGTH      = 500
  LOCATION_MAX_LENGTH = 100

  # One normalization for every handle writer (signup confirmation, settings
  # rename, add_user!): free text like "Jane Smith" becomes "Jane-Smith", and
  # blank input becomes nil so auto-generation kicks in. Case is PRESERVED
  # (`preserve_case: true`) so the display form remembers the case the user
  # chose ("Linus" stays "Linus"); the `handle` column is `citext`, so lookup
  # and the (tenant_id, handle) uniqueness index are case-insensitive
  # regardless ("Linus" and "linus" resolve to and collide with each other).
  normalizes :handle, with: ->(h) { h.to_s.parameterize(preserve_case: true).presence }

  validate :reserved_handle_requires_matching_system_role
  # allow_nil: on create, auto-generated handles are filled in set_defaults
  # (before_create, after validation) and are uniquified there; only
  # explicitly chosen handles need the friendly validation. if: skips the
  # lookup on the frequent saves that don't touch the handle (pins, roles,
  # notices, settings). The DB unique index on (tenant_id, handle) remains
  # the race backstop.
  validates :handle, uniqueness: { scope: :tenant_id }, allow_nil: true, if: :will_save_change_to_handle?
  validates :bio,      length: { maximum: BIO_MAX_LENGTH }, allow_blank: true
  validates :location, length: { maximum: LOCATION_MAX_LENGTH }, allow_blank: true
  validate  :website_scheme_is_http_or_https

  sig { void }
  def set_defaults
    self.handle = handle.presence || generated_default_handle
    self.display_name = display_name.presence || T.must(user).name
    self.settings ||= {}
    T.must(self.settings)["pinned"] ||= {}
    T.must(self.settings)["roles"] ||= []
    T.must(T.must(self.settings)["roles"]) << "default"
  end

  sig { void }
  def website_scheme_is_http_or_https
    url = website
    return if url.blank?

    uri = URI.parse(url)
    return if ["http", "https"].include?(uri.scheme) && uri.hostname.present?

    errors.add(:website, "must be an http or https URL")
  rescue URI::InvalidURIError
    errors.add(:website, "is not a valid URL")
  end

  sig { void }
  def reserved_handle_requires_matching_system_role
    # Reserved keys are lowercase; fold the (now case-preserving) handle so
    # "Trio"/"TRIO" can't slip past the system-role gate.
    return if handle.blank?

    required_role = RESERVED_HANDLES[handle.downcase]
    return unless required_role
    return if T.must(user).system_role == required_role

    errors.add(:handle, "is reserved")
  end

  # Default handle for a user joining a tenant. Prefers the username from an
  # external OAuth identity (e.g. the GitHub username — already unique and
  # handle-shaped) and falls back to the user's name. Suffixed if the
  # parameterized form lands on a reserved handle the user isn't entitled
  # to claim (a human named "Trio" gets "trio-XX", not "trio") or is already
  # taken by another user in this tenant (the second "Jane Smith" gets
  # "jane-smith-XX" instead of a unique-constraint crash on signup). Public
  # so the invite confirmation page can prefill its handle field with the
  # same value auto-generation would use.
  sig { params(tenant_id: String, user: User).returns(String) }
  def self.default_handle_for(tenant_id:, user:)
    oauth_username = user.external_oauth_identities.where.not(username: [nil, ""]).pick(:username)
    base = (oauth_username.presence || user.name).parameterize
    # Names with no parameterizable characters (e.g. CJK or emoji-only)
    # yield "" — fall back to a neutral base rather than an empty handle.
    base = "user" if base.blank?
    required_role = RESERVED_HANDLES[base]
    candidate = base
    candidate = "#{base}-#{SecureRandom.hex(2)}" unless required_role.nil? || user.system_role == required_role
    candidate = "#{base}-#{SecureRandom.hex(2)}" while tenant_scoped_only(tenant_id).exists?(handle: candidate)
    candidate
  end

  sig { returns(String) }
  def generated_default_handle
    self.class.default_handle_for(tenant_id: T.must(tenant_id), user: user)
  end
  private :generated_default_handle

  # Pick a tenant-unique handle for a collective's identity user, sharing the
  # collective's own handle so `@foo-team` and `/collectives/foo-team` resolve
  # to one identity. Case is preserved (`preserve_case: true`) so the identity
  # displays the case the collective chose. Falls back to a numeric suffix
  # (`foo-team-XX`) when the desired handle is already held by another user in
  # the tenant (legacy data where a human grabbed it first) or is a reserved
  # handle the identity can't claim — matching the suffix policy used for human
  # handles in `default_handle_for`. `except_user_id` lets a rename skip the
  # identity's own current row so it isn't treated as a self-collision.
  sig { params(tenant_id: String, base: String, except_user_id: T.nilable(String)).returns(String) }
  def self.identity_handle_for(tenant_id:, base:, except_user_id: nil)
    root = base.to_s.parameterize(preserve_case: true).presence || "collective"
    scope = tenant_scoped_only(tenant_id)
    scope = scope.where.not(user_id: except_user_id) if except_user_id.present?
    candidate = root
    # Identity users never carry a system_role, so any reserved key is off-limits.
    candidate = "#{root}-#{SecureRandom.hex(2)}" if RESERVED_HANDLES.key?(root.downcase)
    candidate = "#{root}-#{SecureRandom.hex(2)}" while scope.exists?(handle: candidate)
    candidate
  end

  sig { returns(User) }
  def user
    @user ||= super
    u = T.must(@user)
    # Back-populate the user's cached tenant_user so later callers don't query
    # for it. Check @tenant_user directly — `u.tenant_user ||= self` would
    # invoke the getter, which fires SQL when the slot is empty.
    u.tenant_user = self unless u.instance_variable_get(:@tenant_user)
    u
  end

  sig { void }
  def archive!
    self.archived_at = T.cast(Time.current, ActiveSupport::TimeWithZone)
    save!
  end

  sig { void }
  def unarchive!
    self.archived_at = nil
    save!
  end

  sig { returns(T::Boolean) }
  def archived?
    archived_at.present?
  end

  sig { returns(String) }
  def path
    "/u/#{handle}"
  end

  sig { returns(String) }
  def url
    "#{T.must(tenant).url}#{path}"
  end

  sig { params(limit: Integer).returns(ActiveRecord::Relation) }
  def confirmed_read_note_events(limit: 10)
    NoteHistoryEvent.where(
      tenant_id: tenant_id,
      user_id: user_id,
      event_type: "read_confirmation"
    ).includes(:note).order(happened_at: :desc).limit(limit)
  end

  # Notification Preferences
  # Default preferences for each notification type
  # web_push defaults on for every type: the real opt-in is registering a
  # device (no subscription → the channel is never returned), so a fresh
  # subscription starts delivering everything and users fine-tune from there.
  DEFAULT_NOTIFICATION_PREFERENCES = T.let({
    "mention" => { "in_app" => true, "email" => true, "web_push" => true },
    "comment" => { "in_app" => true, "email" => false, "web_push" => true },
    "participation" => { "in_app" => true, "email" => false, "web_push" => true },
    "system" => { "in_app" => true, "email" => true, "web_push" => true },
    "reminder" => { "in_app" => true, "email" => false, "web_push" => true },
    "chat_message" => { "in_app" => true, "email" => false, "web_push" => true },
    "trio_unavailable" => { "in_app" => true, "email" => false, "web_push" => true },
    "tune_in" => { "in_app" => true, "email" => false, "web_push" => true },
    # Trustee authorization lifecycle (offered/accepted/declined/revoked).
    # In-app by default, matching most types; users can opt into email.
    "trustee_authorization" => { "in_app" => true, "email" => false, "web_push" => true },
  }.freeze, T::Hash[String, T::Hash[String, T::Boolean]])

  # User-facing labels for each notification type, in display order. Keys must
  # stay in sync with DEFAULT_NOTIFICATION_PREFERENCES and
  # Notification::NOTIFICATION_TYPES. Drives the settings UI and the markdown
  # action surface.
  NOTIFICATION_TYPE_LABELS = T.let({
    "mention" => "Mentions",
    "comment" => "Comments",
    "participation" => "Participation (votes, joins, RSVPs)",
    "system" => "System & account",
    "reminder" => "Reminders",
    "chat_message" => "Chat messages",
    "trio_unavailable" => "Trio unavailable",
    "tune_in" => "Tune-ins",
    "trustee_authorization" => "Trustee authorizations",
  }.freeze, T::Hash[String, String])

  # Delivery channels a user can toggle per notification type.
  NOTIFICATION_CHANNELS = T.let(["in_app", "email", "web_push"].freeze, T::Array[String])

  sig { returns(T::Hash[String, T::Hash[String, T::Boolean]]) }
  def notification_preferences
    settings_hash = T.cast(settings, T.nilable(T::Hash[String, T.untyped]))
    return DEFAULT_NOTIFICATION_PREFERENCES.deep_dup unless settings_hash

    prefs = settings_hash["notification_preferences"]
    return DEFAULT_NOTIFICATION_PREFERENCES.deep_dup unless prefs.is_a?(Hash)

    # Stored values win, but merged over the defaults: prefs saved before a
    # channel existed have no key for it, and a missing key must mean "the
    # default for that channel", not "off". Without this, adding a channel
    # silently disables it for every user who ever saved preferences.
    T.cast(
      DEFAULT_NOTIFICATION_PREFERENCES.deep_merge(T.cast(prefs, T::Hash[String, T::Hash[String, T::Boolean]])),
      T::Hash[String, T::Hash[String, T::Boolean]]
    )
  end

  sig { params(notification_type: String).returns(T::Array[String]) }
  def notification_channels_for(notification_type)
    prefs = notification_preferences[notification_type] || DEFAULT_NOTIFICATION_PREFERENCES[notification_type] || {}
    channels = []
    channels << "in_app" if prefs["in_app"]
    # Non-human users (ai_agent, collective_identity) have no routable email
    # address, so never return the email channel for them regardless of stored
    # prefs. Keeps every caller (dispatcher, reminder service, trustee path)
    # honest and avoids creating an email NotificationRecipient that can't deliver.
    channels << "email" if prefs["email"] && user.human?
    # web_push requires a live device registration on top of the stored pref —
    # a subscription is the user's real opt-in, and skipping the channel when
    # they have no active device avoids creating NotificationRecipient rows
    # that could never deliver.
    channels << "web_push" if prefs["web_push"] && user.human? && web_push_available?
    channels
  end

  sig { returns(T::Boolean) }
  def web_push_available?
    T.must(tenant).web_push_available? && user.web_push_subscriptions.active.exists?
  end

  sig { params(notification_type: String, channel: String).returns(T::Boolean) }
  def notification_enabled?(notification_type, channel)
    prefs = notification_preferences[notification_type] || DEFAULT_NOTIFICATION_PREFERENCES[notification_type] || {}
    prefs[channel] == true
  end

  sig { params(notification_type: String, channel: String, enabled: T::Boolean).void }
  def set_notification_preference!(notification_type, channel, enabled)
    self.settings ||= {}
    settings_hash = T.cast(settings, T::Hash[String, T.untyped])
    # Seed empty, not the defaults matrix: notification_preferences merges
    # stored values over DEFAULT_NOTIFICATION_PREFERENCES at read time, so
    # only explicit choices belong in settings. Copying the defaults in
    # would freeze today's defaults (and today's channel list) forever.
    settings_hash["notification_preferences"] ||= {}
    notification_prefs = T.cast(settings_hash["notification_preferences"], T::Hash[String, T::Hash[String, T::Boolean]])
    notification_prefs[notification_type] ||= {}
    T.must(notification_prefs[notification_type])[channel] = enabled
    save!
  end

  # Bulk-update notification preferences from a nested hash of
  # { type => { channel => bool } }. Unknown types/channels are ignored;
  # types/channels absent from the hash are left unchanged (merge, not replace),
  # so partial updates from the markdown action surface are safe. The HTML
  # settings form passes a complete matrix, so every box reflects its state.
  sig { params(preferences: T::Hash[String, T::Hash[String, T::Boolean]]).void }
  def update_notification_preferences!(preferences)
    self.settings ||= {}
    settings_hash = T.cast(settings, T::Hash[String, T.untyped])
    # Empty seed for the same reason as set_notification_preference!: stored
    # prefs hold only explicit choices; defaults are merged in at read time.
    settings_hash["notification_preferences"] ||= {}
    current = T.cast(settings_hash["notification_preferences"], T::Hash[String, T::Hash[String, T::Boolean]])

    preferences.each do |type, channels|
      next unless NOTIFICATION_TYPE_LABELS.key?(type)
      next unless channels.is_a?(Hash)

      current[type] ||= {}
      channels.each do |channel, enabled|
        next unless NOTIFICATION_CHANNELS.include?(channel)

        # Non-human users can never carry a stored email:true — the markdown
        # action surface accepts arbitrary payloads and the simple-mode form
        # omits the email column, so coerce it to false at write time to keep
        # persisted state clean.
        enabled = false if channel == "email" && !user.human?
        T.must(current[type])[channel] = enabled
      end
    end
    save!
  end
end
