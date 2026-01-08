# typed: true

class StudioUser < ApplicationRecord
  extend T::Sig

  include HasRoles
  include HasDismissibleNotices
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :studio
  belongs_to :user

  validate :trustee_users_not_member_of_main_studio

  sig { void }
  def trustee_users_not_member_of_main_studio
    if user.trustee? && studio == T.must(tenant).main_studio
      errors.add(:user, "Trustee users cannot be members of the main studio")
    end
  end

  sig { returns(User) }
  def user
    @user ||= super
    T.must(@user).studio_user ||= self
    T.must(@user)
  end

  sig { params(limit: Integer).returns(ActiveRecord::Relation) }
  def confirmed_read_note_events(limit: 10)
    NoteHistoryEvent.where(
      tenant_id: tenant_id,
      studio_id: studio_id,
      user_id: user_id,
      event_type: 'read_confirmation',
    ).includes(:note).order(happened_at: :desc).limit(limit)
  end

  sig { params(limit: Integer).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def latest_note_reads(limit: 10)
    T.unsafe(NoteHistoryEvent.where(
      tenant_id: tenant_id,
      studio_id: studio_id,
      user_id: user_id,
      event_type: 'read_confirmation',
    ).includes(:note))
    .distinct(:note_id)
    .order(happened_at: :desc)
    .limit(limit)
    .map do |nhe|
      {
        note: nhe.note,
        read_at: nhe.happened_at,
      }
    end
  end

  sig { params(limit: Integer).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def latest_votes(limit: 10)
    DecisionParticipant.where(
      tenant_id: tenant_id,
      studio_id: studio_id,
      user_id: user_id,
    ).includes(:approvals)
    .where.not(approvals: {id: nil})
    .includes(:decision)
    .order(created_at: :desc)
    .limit(limit)
    .map do |dp|
      {
        decision: dp.decision,
        voted_at: T.must(dp.approvals.max_by(&:updated_at)).updated_at,
      }
    end
  end

  sig { params(limit: Integer).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def latest_commitment_joins(limit: 10)
    CommitmentParticipant.where(
      tenant_id: tenant_id,
      studio_id: studio_id,
      user_id: user_id,
    ).where.not(committed_at: nil)
    .includes(:commitment)
    .order(created_at: :desc)
    .limit(limit)
    .map do |cp|
      {
        commitment: cp.commitment,
        joined_at: cp.created_at,
      }
    end
  end

  sig { returns(T::Boolean) }
  def can_invite?
    archived_at.nil? && (has_role?('admin') || T.must(studio).allow_invites?)
  end

  sig { returns(T::Boolean) }
  def can_edit_settings?
    archived_at.nil? && has_role?('admin')
  end

  sig { returns(T::Boolean) }
  def can_represent?
    archived_at.nil? && (has_role?('representative') || T.must(studio).any_member_can_represent?)
  end

  sig { returns(T.nilable(String)) }
  def path
    if user.trustee?
      s = Studio.where(trustee_user: user).first
      s&.path
    else
      "#{T.must(studio).path}/u/#{user.handle}"
    end
  end

end
