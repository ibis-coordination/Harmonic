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
    self.handle = self.handle.presence || T.must(user).name.parameterize
    self.display_name = display_name.presence || T.must(user).name
    self.settings ||= {}
    T.must(self.settings)['pinned'] ||= {}
    T.must(self.settings)['roles'] ||= []
    T.must(T.must(self.settings)['roles']) << 'default'
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
    self.archived_at.present?
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
      event_type: 'read_confirmation',
    ).includes(:note).order(happened_at: :desc).limit(limit)
  end
end
