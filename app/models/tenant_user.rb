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

  validate :reserved_handle_requires_matching_system_role

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
  def reserved_handle_requires_matching_system_role
    required_role = RESERVED_HANDLES[handle]
    return unless required_role
    return if T.must(user).system_role == required_role

    errors.add(:handle, "is reserved")
  end

  # When auto-generating a handle from the user's name, suffix it if the
  # parameterized form lands on a reserved handle the user isn't entitled
  # to claim — so a human named "Trio" gets "trio-XX", not "trio".
  sig { returns(String) }
  def generated_default_handle
    base = T.must(user).name.parameterize
    required_role = RESERVED_HANDLES[base]
    return base if required_role.nil? || T.must(user).system_role == required_role

    "#{base}-#{SecureRandom.hex(2)}"
  end
  private :generated_default_handle

  sig { returns(User) }
  def user
    @user ||= super
    T.must(@user).tenant_user ||= self
    T.must(@user)
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
