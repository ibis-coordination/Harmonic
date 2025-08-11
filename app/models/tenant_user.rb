class TenantUser < ApplicationRecord
  include CanPin
  include HasRoles
  include HasDismissibleNotices
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :user
  before_create :set_defaults

  def set_defaults
    self.handle = self.handle.presence || user.name.parameterize
    self.display_name ||= user.name
    self.settings ||= {}
    self.settings['pinned'] ||= {}
    self.roles ||= []
    self.roles << 'default'
  end

  def user
    @user ||= super
    @user.tenant_user ||= self
    @user
  end

  def archive!
    self.archived_at = Time.current
    save!
  end

  def unarchive!
    self.archived_at = nil
    save!
  end

  def archived?
    self.archived_at.present?
  end

  def path
    "/u/#{handle}"
  end

  def url
    "#{tenant.url}#{path}"
  end

  def confirmed_read_note_events(limit: 10)
    NoteHistoryEvent.where(
      tenant_id: tenant_id,
      user_id: user_id,
      event_type: 'read_confirmation',
    ).includes(:note).order(happened_at: :desc).limit(limit)
  end
end
