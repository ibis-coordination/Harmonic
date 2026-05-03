# typed: true

class ChatSession < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :collective
  belongs_to :user_one, class_name: "User"
  belongs_to :user_two, class_name: "User"

  has_many :task_runs, class_name: "AiAgentTaskRun", dependent: :nullify
  has_many :chat_messages, dependent: :destroy

  validates :user_one_id, uniqueness: { scope: [:tenant_id, :user_two_id] }

  # Find or create a 1-on-1 chat session between two users.
  # Participants are stored in canonical order (lower UUID first)
  # so the unique index works regardless of who initiates.
  sig { params(user_a: User, user_b: User, tenant: Tenant).returns(ChatSession) }
  def self.find_or_create_between(user_a:, user_b:, tenant:)
    one, two = [user_a.id, user_b.id].sort
    find_or_create_by!(
      tenant: tenant,
      user_one_id: one,
      user_two_id: two,
    )
  rescue ActiveRecord::RecordNotUnique
    one, two = [user_a.id, user_b.id].sort
    find_by!(
      tenant: tenant,
      user_one_id: one,
      user_two_id: two,
    )
  end

  # Returns the other participant in this session.
  sig { params(user: User).returns(User) }
  def other_participant(user)
    T.must(user.id == user_one_id ? user_two : user_one)
  end

  # Returns true if the user is a participant in this session.
  sig { params(user: User).returns(T::Boolean) }
  def participant?(user)
    user.id == user_one_id || user.id == user_two_id
  end

  sig { returns(T.untyped) }
  def messages
    chat_messages.order(:created_at)
  end
end
