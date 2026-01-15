# typed: true

class Tenant < ApplicationRecord
  extend T::Sig
  include HasFeatureFlags

  self.implicit_order_column = "created_at"
  has_many :tenant_users
  has_many :users, through: :tenant_users
  belongs_to :main_superagent, class_name: 'Superagent', optional: true # Only optional so that we can create the main superagent after the tenant is created
  before_create :set_defaults
  # Admin controller handles this. Callbacks are buggy.
  # after_create :create_main_superagent!

  tables = ActiveRecord::Base.connection.tables - [
    'tenants', 'users', 'oauth_identities',
    'tenant_users', # Explicitly defined above with through association
    # Rails internal tables
    'ar_internal_metadata', 'schema_migrations',
    'active_storage_attachments', 'active_storage_blobs',
    'active_storage_variant_records',
  ]
  tables.each do |table|
    has_many table.to_sym
  end

  sig { params(subdomain: String).returns(Tenant) }
  def self.scope_thread_to_tenant(subdomain:)
    if subdomain == ENV['AUTH_SUBDOMAIN']
      tenant = Tenant.new(
        id: SecureRandom.uuid,
        name: 'Harmonic Team',
        subdomain: ENV['AUTH_SUBDOMAIN'],
        settings: { 'require_login' => false }
      )
    else
      tenant = find_by(subdomain: subdomain)
    end
    if tenant
      self.current_subdomain = tenant.subdomain
      self.current_id = tenant.id
      self.current_main_superagent_id = tenant.main_superagent_id
    else
      raise "Invalid subdomain"
    end
    tenant
  end

  sig { void }
  def self.clear_thread_scope
    Thread.current[:tenant_id] = nil
    Thread.current[:tenant_handle] = nil
  end

  sig { returns(T.nilable(String)) }
  def self.current_subdomain
    Thread.current[:tenant_subdomain]
  end

  sig { returns(T.nilable(String)) }
  def self.current_id
    Thread.current[:tenant_id]
  end

  sig { returns(T.nilable(String)) }
  def self.current_main_superagent_id
    Thread.current[:main_superagent_id]
  end

  sig { returns(ActiveRecord::Relation) }
  def self.all_public_tenants
    unscoped.where(
      subdomain: [
        [ENV['PRIMARY_SUBDOMAIN']],
        ENV.fetch('OTHER_PUBLIC_TENANTS', nil)&.split(',')
      ].compact.flatten
    )
  end

  sig { returns(String) }
  def path
    "/"
  end

  sig { void }
  def set_defaults
    return unless self.respond_to?(:settings)
    self.settings = ({
      timezone: 'UTC',
      require_login: true,
      require_invite: true,
      auth_providers: ['github'],
      allow_file_uploads: false,
      allow_main_studio_items: false,
      api_enabled: false,
      default_studio_settings: {
        tempo: 'daily',
        synchronization_mode: 'improv',
        all_members_can_invite: false,
        any_member_can_represent: false,
        api_enabled: false,
        allow_file_uploads: true,
        file_upload_limit: 100.megabytes,
      }
    }).merge(self.settings || {})
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def default_studio_settings
    self.settings['default_studio_settings'] || {}
  end

  sig { returns(T::Array[String]) }
  def auth_providers
    settings['auth_providers'] || ['github']
  end

  sig { params(providers: T::Array[String]).void }
  def auth_providers=(providers)
    self.settings['auth_providers'] = providers
  end

  sig { params(provider: String).void }
  def add_auth_provider!(provider)
    self.settings['auth_providers'] = (self.settings['auth_providers'] || []) + [provider]
    save!
  end

  sig { params(provider: String).returns(T::Boolean) }
  def valid_auth_provider?(provider)
    self.settings['auth_providers'].include?(provider)
  end

  sig { params(value: T.nilable(String)).void }
  def timezone=(value)
    if value.present?
      @timezone = ActiveSupport::TimeZone[value]
      set_defaults
      self.settings = self.settings.merge('timezone' => T.must(@timezone).name)
      T.must(main_superagent).timezone = T.must(@timezone).name
      T.must(main_superagent).save!
    end
  end

  sig { returns(ActiveSupport::TimeZone) }
  def timezone
    @timezone ||= self.settings['timezone'] ? ActiveSupport::TimeZone[self.settings['timezone']] : ActiveSupport::TimeZone['UTC']
  end

  sig { returns(T::Boolean) }
  def allow_main_studio_items?
    settings['allow_main_studio_items'].to_s == 'true'
  end

  sig { returns(T::Boolean) }
  def allow_file_uploads?
    file_attachments_enabled?
  end

  sig { returns(T::Boolean) }
  def file_attachments_enabled?
    # Use unified feature flag system with legacy fallback
    if feature_flags_hash.key?("file_attachments")
      FeatureFlagService.tenant_enabled?(self, "file_attachments")
    else
      # Legacy: check old setting location
      FeatureFlagService.app_enabled?("file_attachments") &&
        settings["allow_file_uploads"].to_s == "true"
    end
  end

  sig { returns(T::Boolean) }
  def api_enabled?
    # Use unified feature flag system with legacy fallback
    if feature_flags_hash.key?("api")
      FeatureFlagService.tenant_enabled?(self, "api")
    else
      # Legacy: check old setting location
      FeatureFlagService.app_enabled?("api") &&
        settings["api_enabled"].to_s == "true"
    end
  end

  # Check if a feature is enabled at the tenant level (with cascade from app)
  sig { params(flag_name: String).returns(T::Boolean) }
  def feature_enabled?(flag_name)
    FeatureFlagService.tenant_enabled?(self, flag_name)
  end

  sig { void }
  def enable_api!
    set_feature_flag!("api", true)
  end

  sig { params(created_by: User).void }
  def create_main_superagent!(created_by:)
    self.main_superagent = superagents.create!(
      name: "#{self.subdomain}.#{ENV['HOSTNAME']}",
      handle: SecureRandom.hex(16),
      created_by: created_by,
    )
    # Always enable API for the main superagent
    # Both tenant and superagent must have API enabled for it to be accessible
    T.must(main_superagent).enable_api!
    save!
  end

  sig { params(user: User).returns(TenantUser) }
  def add_user!(user)
    tenant_users.create!(
      user: user,
      display_name: user.name,
      handle: user.name.parameterize
    )
  end

  sig { returns(T.nilable(String)) }
  def description
    settings['description']
  end

  sig { params(limit: Integer).returns(T::Array[User]) }
  def team(limit: 100)
    tenant_users
      .where(archived_at: nil)
      .includes(:user)
      .limit(limit)
      .order(created_at: :desc).map do |tu|
        tu.user.tenant_user = tu
        tu.user
    end
  end

  sig { params(user: User).returns(T::Boolean) }
  def is_admin?(user)
    tu = tenant_users.find_by(user: user)
    !!(tu && tu.roles.include?('admin'))
  end

  sig { returns(ActiveRecord::Relation) }
  def admin_users
    T.unsafe(tenant_users).where_has_role('admin')
  end

  sig { returns(T::Boolean) }
  def require_login?
    settings['require_login'].to_s == 'false' ? false : true
  end

  sig { returns(String) }
  def domain
    "#{subdomain}.#{ENV['HOSTNAME']}"
  end

  sig { returns(String) }
  def url
    "https://#{domain}"
  end

  sig { returns(T::Boolean) }
  def archived?
    archived_at.present?
  end

  sig { void }
  def archive!
    self.archived_at = T.cast(Time.current, ActiveSupport::TimeWithZone)
    save!
  end

  private

  sig { params(subdomain: T.nilable(String)).void }
  def self.current_subdomain=(subdomain)
    Thread.current[:tenant_subdomain] = subdomain
  end

  sig { params(id: T.nilable(String)).void }
  def self.current_id=(id)
    Thread.current[:tenant_id] = id
  end

  sig { params(id: T.nilable(String)).void }
  def self.current_main_superagent_id=(id)
    Thread.current[:main_superagent_id] = id
  end

  # Aliases for backwards compatibility with code that uses "studio" terminology
  def main_studio
    T.unsafe(self).main_superagent
  end
  alias_attribute :main_studio_id, :main_superagent_id

  def studios
    T.unsafe(self).superagents
  end

  def create_main_studio!
    T.unsafe(self).create_main_superagent!
  end
end
