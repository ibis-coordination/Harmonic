# typed: true

class SuperagentMember < ApplicationRecord
  extend T::Sig

  include HasRoles
  include HasDismissibleNotices
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :superagent
  belongs_to :user

  validate :trustee_users_not_member_of_main_superagent

  sig { void }
  def trustee_users_not_member_of_main_superagent
    if user.trustee? && superagent == T.must(tenant).main_superagent
      errors.add(:user, "Trustee users cannot be members of the main superagent")
    end
  end

  sig { returns(User) }
  def user
    @user ||= super
    T.must(@user).superagent_member ||= self
    T.must(@user)
  end

  sig { params(limit: Integer).returns(ActiveRecord::Relation) }
  def confirmed_read_note_events(limit: 10)
    NoteHistoryEvent.where(
      tenant_id: tenant_id,
      superagent_id: superagent_id,
      user_id: user_id,
      event_type: 'read_confirmation',
    ).includes(:note).order(happened_at: :desc).limit(limit)
  end

  sig { params(limit: Integer).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def latest_note_reads(limit: 10)
    T.unsafe(NoteHistoryEvent.where(
      tenant_id: tenant_id,
      superagent_id: superagent_id,
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
      superagent_id: superagent_id,
      user_id: user_id,
    ).includes(:votes)
    .where.not(votes: {id: nil})
    .includes(:decision)
    .order(created_at: :desc)
    .limit(limit)
    .map do |dp|
      {
        decision: dp.decision,
        voted_at: T.must(dp.votes.max_by(&:updated_at)).updated_at,
      }
    end
  end

  sig { params(limit: Integer).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def latest_commitment_joins(limit: 10)
    CommitmentParticipant.where(
      tenant_id: tenant_id,
      superagent_id: superagent_id,
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
    archived_at.nil? && (has_role?('admin') || T.must(superagent).allow_invites?)
  end

  sig { returns(T::Boolean) }
  def can_edit_settings?
    archived_at.nil? && has_role?('admin')
  end

  sig { returns(T::Boolean) }
  def can_represent?
    archived_at.nil? && (has_role?('representative') || T.must(superagent).any_member_can_represent?)
  end

  # Alias for backwards compatibility
  sig { returns(T::Boolean) }
  def is_admin?
    has_role?('admin')
  end

  sig { returns(T.nilable(String)) }
  def path
    if user.trustee?
      s = Superagent.where(trustee_user: user).first
      s&.path
    else
      "#{T.must(superagent).path}/u/#{user.handle}"
    end
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

end
