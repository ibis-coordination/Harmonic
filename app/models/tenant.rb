class Tenant < ApplicationRecord
  self.implicit_order_column = "created_at"
  has_many :tenant_users
  has_many :users, through: :tenant_users
  belongs_to :main_studio, class_name: 'Studio', optional: true # Only optional so that we can create the main studio after the tenant is created
  before_create :set_defaults
  # Admin controller handles this. Callbacks are buggy.
  # after_create :create_main_studio!

  tables = ActiveRecord::Base.connection.tables - [
    'tenants', 'users', 'oauth_identities',
    # Rails internal tables
    'ar_internal_metadata', 'schema_migrations',
    'active_storage_attachments', 'active_storage_blobs',
    'active_storage_variant_records',
  ]
  tables.each do |table|
    has_many table.to_sym
  end

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
      self.current_main_studio_id = tenant.main_studio_id
    else
      raise "Invalid subdomain"
    end
    tenant
  end

  def self.clear_thread_scope
    Thread.current[:tenant_id] = nil
    Thread.current[:tenant_handle] = nil
  end

  def self.current_subdomain
    Thread.current[:tenant_subdomain]
  end

  def self.current_id
    Thread.current[:tenant_id]
  end

  def self.current_main_studio_id
    Thread.current[:main_studio_id]
  end

  def self.all_public_tenants
    unscoped.where(
      subdomain: [
        [ENV['PRIMARY_SUBDOMAIN']],
        ENV.fetch('OTHER_PUBLIC_TENANTS', nil)&.split(',')
      ].compact.flatten
    )
  end

  def path
    "/"
  end

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

  def default_studio_settings
    self.settings['default_studio_settings'] || {}
  end

  def auth_providers
    settings['auth_providers'] || ['github']
  end

  def auth_providers=(providers)
    self.settings['auth_providers'] = providers
  end

  def add_auth_provider!(provider)
    self.settings['auth_providers'] = (self.settings['auth_providers'] || []) + [provider]
    save!
  end

  def timezone=(value)
    if value.present?
      @timezone = ActiveSupport::TimeZone[value]
      set_defaults
      self.settings = self.settings.merge('timezone' => @timezone.name)
      self.main_studio.timezone = @timezone.name
      self.main_studio.save!
    end
  end

  def timezone
    @timezone ||= self.settings['timezone'] ? ActiveSupport::TimeZone[self.settings['timezone']] : ActiveSupport::TimeZone['UTC']
  end

  def allow_main_studio_items?
    settings['allow_main_studio_items'].to_s == 'true'
  end

  def allow_file_uploads?
    settings['allow_file_uploads'].to_s == 'true'
  end

  def api_enabled?
    settings['api_enabled'].to_s == 'true'
  end

  def enable_api!
    self.settings['api_enabled'] = true
    save!
  end

  def create_main_studio!(created_by:)
    self.main_studio = studios.create!(
      name: "#{self.subdomain}.#{ENV['HOSTNAME']}",
      handle: SecureRandom.hex(16),
      created_by: created_by,
    )
    # Always enable API for the main studio
    # Both tenant and studio must have API enabled for it to be accessible
    self.main_studio.enable_api!
    save!
  end

  def add_user!(user)
    tenant_users.create!(
      user: user,
      display_name: user.name,
      handle: user.name.parameterize
    )
  end

  def description
    settings['description']
  end

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

  def is_admin?(user)
    tu = tenant_users.find_by(user: user)
    tu && tu.roles.include?('admin')
  end

  def admin_users
    tenant_users.where_has_role('admin')
  end

  def auth_providers
    settings['auth_providers'] || ['github']
  end

  def require_login?
    settings['require_login'].to_s == 'false' ? false : true
  end

  def domain
    "#{subdomain}.#{ENV['HOSTNAME']}"
  end

  def url
    "https://#{domain}"
  end

  private

  def self.current_subdomain=(subdomain)
    Thread.current[:tenant_subdomain] = subdomain
  end

  def self.current_id=(id)
    Thread.current[:tenant_id] = id
  end

  def self.current_main_studio_id=(id)
    Thread.current[:main_studio_id] = id
  end
end
