class Studio < ApplicationRecord
  include CanPin
  include HasImage
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :created_by, class_name: 'User'
  belongs_to :updated_by, class_name: 'User'
  belongs_to :trustee_user, class_name: 'User'
  before_validation :create_trustee!
  before_create :set_defaults
  tables = ActiveRecord::Base.connection.tables - [
    'tenants', 'users', 'tenant_users',
    'studios', 'api_tokens', 'oauth_identities',
    # Rails internal tables
    'ar_internal_metadata', 'schema_migrations',
    'active_storage_attachments', 'active_storage_blobs',
    'active_storage_variant_records',
  ]
  tables.each do |table|
    has_many table.to_sym
  end
  has_many :users, through: :studio_users
  validate :handle_is_valid
  validate :creator_is_not_trustee, on: :create

  # NOTE: This is commented out because there is a bug where
  # the corresponding note history event is not created
  # when the note itself is created within a callback.
  # So we rely on the controller to create the welcome note.
  # after_create :create_welcome_note!

  def self.scope_thread_to_studio(subdomain:, handle:)
    tenant = Tenant.scope_thread_to_tenant(subdomain: subdomain)
    studio = handle ? tenant.studios.find_by!(handle: handle) : tenant.main_studio
    if studio.nil? && subdomain == ENV['AUTH_SUBDOMAIN']
      studio = Studio.new(
        id: SecureRandom.uuid,
        name: 'Harmonic Team',
        handle: SecureRandom.hex(16),
        tenant: tenant,
      )
      tenant.main_studio = studio
    end
    Thread.current[:studio_id] = studio.id
    Thread.current[:studio_handle] = studio.handle
    studio
  end

  def self.current_handle
    Thread.current[:studio_handle]
  end

  def self.current_id
    Thread.current[:studio_id]
  end

  def self.handle_available?(handle)
    Studio.where(handle: handle).count == 0
  end

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
      self.tenant.default_studio_settings || {}
    ).merge(
      self.settings || {}
    )
  end

  def creator_is_not_trustee
    errors.add(:created_by, "cannot be a trustee") if created_by.trustee?
  end

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

  def api_enabled?
    feature_enabled?('api')
  end

  def enable_api!
    enable_feature!('api')
    save!
  end

  def feature_enabled?(feature)
    feature_flags = self.settings['feature_flags'] || {}
    feature_flags[feature].to_s == 'true' || self.settings["#{feature}_enabled"].to_s == 'true'
  end

  def sequences_enabled?
    feature_enabled?('sequences')
  end

  def timezone=(value)
    if value.present?
      @timezone = ActiveSupport::TimeZone[value]
      set_defaults
      self.settings = self.settings.merge('timezone' => @timezone.name)
    end
  end

  def timezone
    @timezone ||= self.settings['timezone'] ? ActiveSupport::TimeZone[self.settings['timezone']] : ActiveSupport::TimeZone['UTC']
  end

  def tempo=(value)
    if ['daily', 'weekly', 'monthly'].include?(value)
      set_defaults
      self.settings = self.settings.merge('tempo' => value)
    end
  end

  def tempo
    self.settings['tempo'] || 'weekly'
  end

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

  def synchronization_mode=(value)
    if ['improv', 'orchestra'].include?(value)
      set_defaults
      self.settings = self.settings.merge('synchronization_mode' => value)
    end
  end

  def synchronization_mode
    self.settings['synchronization_mode'] || 'improv'
  end

  def improv?
    self.synchronization_mode == 'improv'
  end

  def orchestra?
    self.synchronization_mode == 'orchestra'
  end

  def enable_feature!(feature)
    self.settings["feature_flags"] ||= {}
    self.settings["feature_flags"][feature] = true
    save!
  end

  def disable_feature!(feature)
    self.settings["#{feature}_enabled"] = false
    self.settings["feature_flags"] ||= {}
    self.settings["feature_flags"][feature] = false
    save!
  end

  def file_storage_limit
    self.settings['file_storage_limit'] || 100.megabytes
  end

  def file_storage_limit_in_human_size
    ActiveSupport::NumberHelper.number_to_human_size(file_storage_limit)
  end

  def file_storage_usage
    @byte_sum ||= Attachment.where(studio: self).sum(:byte_size)
  end

  def file_storage_usage_in_human_size
    ActiveSupport::NumberHelper.number_to_human_size(file_storage_usage)
  end

  def within_file_upload_limit?
    file_storage_usage < file_storage_limit
  end

  def allow_file_uploads?
    self.settings['allow_file_uploads'].to_s == 'true'
  end

  def handle_is_valid
    if handle.present?
      only_alphanumeric_with_dash = handle.match?(/\A[a-z0-9-]+\z/)
      errors.add(:handle, "must be alphanumeric with dashes") unless only_alphanumeric_with_dash
    else
      errors.add(:handle, "can't be blank")
    end
  end

  def create_trustee!
    return if self.trustee_user
    trustee = User.create!(
      name: self.name,
      email: SecureRandom.uuid + '@not-a-real-email.com',
      user_type: 'trustee',
    )
    tenant_user = TenantUser.create!(
      tenant: tenant,
      user: trustee,
      display_name: trustee.name,
      handle: SecureRandom.hex(16),
    )
    self.trustee_user = trustee
    save!
  end

  def create_welcome_note!
    note = Note.create!(
      tenant: tenant,
      studio: self,
      title: 'Welcome to Harmonic Team',
      text: 'This is a system generated note.',
      created_by: trustee_user,
      deadline: Time.current + 1.week,
    )
    pin_item!(note)
  end

  def open_items
    open_decisions = decisions.where('deadline > ?', Time.current)
    open_commitments = commitments.where('deadline > ?', Time.current)
    (open_decisions + open_commitments).sort_by(&:deadline)
  end

  def recently_closed_items(time_window: 1.week)
    closed_decisions = decisions.where('deadline < ?', Time.current).where('deadline > ?', time_window.ago)
    closed_commitments = commitments.where('deadline < ?', Time.current).where('deadline > ?', time_window.ago)
    (closed_decisions + closed_commitments).sort_by(&:deadline).reverse
  end

  def is_main_studio?
    (Tenant.current_main_studio_id || self.tenant.main_studio_id) == self.id
  end

  def path_prefix
    's'
  end

  def path
    if is_main_studio?
      nil
    else
      "/#{path_prefix}/#{handle}"
    end
  end

  def url
    if handle
      "#{tenant.url}#{path}"
    else
      tenant.url
    end
  end

  def add_user!(user, roles: [])
    su = studio_users.create!(
      tenant: tenant,
      user: user,
    )
    su.add_roles!(roles)
  end

  def user_is_member?(user)
    studio_users.where(user: user).count > 0
  end

  def team(limit: 100)
    studio_users
      .where(archived_at: nil)
      .includes(:user)
      .limit(limit)
      .order(created_at: :desc).map do |su|
        su.user.studio_user = su
        su.user
      end
  end

  def backlink_leaderboard(start_date: nil, end_date: nil, limit: 10)
    Link.backlink_leaderboard(studio_id: self.id)
  end

  def delete!
    raise "Delete not implemented"
    raise "Cannot delete main studio" if is_main_studio?
    # self.archived_at = Time.current
    # save!
  end

  def find_or_create_shareable_invite(created_by)
    invite = StudioInvite.where(
      studio: self,
      invited_user: nil,
    ).where('expires_at > ?', Time.current + 2.days).first
    if invite.nil?
      invite = StudioInvite.create!(
        studio: self,
        created_by: created_by,
        code: SecureRandom.hex(16),
        expires_at: 1.week.from_now,
      )
    end
    invite
  end

  def allow_invites?
    open_to_all = !self.settings['invite_only']
    all_members_can_invite = self.settings['all_members_can_invite']
    open_to_all || all_members_can_invite
  end

  def representatives
    studio_users.where_has_role('representative').map(&:user)
  end

  def admins
    studio_users.where_has_role('admin').map(&:user)
  end

  def all_members_can_invite?
    self.settings['all_members_can_invite']
  end

  def any_member_can_represent?
    self.settings['any_member_can_represent']
  end

  def current_cycle
    Cycle.new_from_studio(self)
  end

end