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
  # rename, add_user!): free text like "Jane Smith" becomes jane-smith, and
  # blank input becomes nil so auto-generation kicks in.
  normalizes :handle, with: ->(h) { h.to_s.parameterize.presence }

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
    required_role = RESERVED_HANDLES[handle]
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
  DEFAULT_NOTIFICATION_PREFERENCES = T.let({
    "mention" => { "in_app" => true, "email" => true },
    "comment" => { "in_app" => true, "email" => false },
    "participation" => { "in_app" => true, "email" => false },
    "system" => { "in_app" => true, "email" => true },
    "reminder" => { "in_app" => true, "email" => false },
    "chat_message" => { "in_app" => true, "email" => false },
    "trio_unavailable" => { "in_app" => true, "email" => false },
    "tune_in" => { "in_app" => true, "email" => false },
  }.freeze, T::Hash[String, T::Hash[String, T::Boolean]])

  sig { returns(T::Hash[String, T::Hash[String, T::Boolean]]) }
  def notification_preferences
    settings_hash = T.cast(settings, T.nilable(T::Hash[String, T.untyped]))
    return DEFAULT_NOTIFICATION_PREFERENCES.deep_dup unless settings_hash

    prefs = settings_hash["notification_preferences"]
    return DEFAULT_NOTIFICATION_PREFERENCES.deep_dup unless prefs.is_a?(Hash)

    T.cast(prefs, T::Hash[String, T::Hash[String, T::Boolean]])
  end

  sig { params(notification_type: String).returns(T::Array[String]) }
  def notification_channels_for(notification_type)
    prefs = notification_preferences[notification_type] || DEFAULT_NOTIFICATION_PREFERENCES[notification_type] || {}
    channels = []
    channels << "in_app" if prefs["in_app"]
    channels << "email" if prefs["email"]
    channels
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
    settings_hash["notification_preferences"] ||= DEFAULT_NOTIFICATION_PREFERENCES.deep_dup
    notification_prefs = T.cast(settings_hash["notification_preferences"], T::Hash[String, T::Hash[String, T::Boolean]])
    notification_prefs[notification_type] ||= {}
    T.must(notification_prefs[notification_type])[channel] = enabled
    save!
  end

end
