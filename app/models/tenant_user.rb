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

  sig { void }
  def set_defaults
    self.handle = handle.presence || T.must(user).name.parameterize
    self.display_name = display_name.presence || T.must(user).name
    self.settings ||= {}
    T.must(self.settings)["pinned"] ||= {}
    T.must(self.settings)["roles"] ||= []
    T.must(T.must(self.settings)["roles"]) << "default"
  end

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
    "reminder" => { "in_app" => true, "email" => false },  # Email disabled by default for AI agents
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

  # UI Version preference for v1/v2 toggle
  UI_VERSIONS = T.let(%w[v1 v2].freeze, T::Array[String])
  DEFAULT_UI_VERSION = T.let("v1", String)

  sig { returns(String) }
  def ui_version
    settings_hash = T.cast(settings, T.nilable(T::Hash[String, T.untyped]))
    return DEFAULT_UI_VERSION unless settings_hash
    version = settings_hash["ui_version"]
    UI_VERSIONS.include?(version) ? T.cast(version, String) : DEFAULT_UI_VERSION
  end

  sig { params(version: String).void }
  def ui_version=(version)
    raise ArgumentError, "Invalid UI version: #{version}" unless UI_VERSIONS.include?(version)
    self.settings ||= {}
    settings_hash = T.cast(settings, T::Hash[String, T.untyped])
    settings_hash["ui_version"] = version
  end

  sig { params(version: String).void }
  def set_ui_version!(version)
    self.ui_version = version
    save!
  end

  sig { returns(T::Boolean) }
  def ui_v2?
    ui_version == "v2"
  end
end
