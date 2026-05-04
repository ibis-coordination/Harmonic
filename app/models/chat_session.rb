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
  validate :collective_must_be_chat_type
  validate :participants_in_canonical_order

  # Find or create a 1-on-1 chat session between two users.
  # Participants are stored in canonical order (lower UUID first)
  # so the unique index works regardless of who initiates.
  #
  # Each session gets a dedicated chat collective with only the two
  # participants as members. This ensures chat message events are
  # scoped to a private collective for automation/webhook privacy.
  sig { params(user_a: User, user_b: User, tenant: Tenant).returns(ChatSession) }
  def self.find_or_create_between(user_a:, user_b:, tenant:)
    one, two = T.cast([user_a.id, user_b.id].sort, [String, String])

    # Look for existing session across all collectives (chat sessions
    # live in per-session chat collectives, not the current collective)
    existing = tenant_scoped_only(tenant.id).find_by(
      user_one_id: one,
      user_two_id: two,
    )
    return existing if existing

    create_with_chat_collective(
      tenant: tenant,
      user_a: user_a,
      user_b: user_b,
      user_one_id: one,
      user_two_id: two,
    )
  rescue ActiveRecord::RecordNotUnique
    tenant_scoped_only(tenant.id).find_by!(
      user_one_id: one,
      user_two_id: two,
    )
  end

  sig do
    params(
      tenant: Tenant,
      user_a: User,
      user_b: User,
      user_one_id: String,
      user_two_id: String,
    ).returns(ChatSession)
  end
  def self.create_with_chat_collective(tenant:, user_a:, user_b:, user_one_id:, user_two_id:)
    chat_collective = Collective.create!(
      tenant: tenant,
      created_by: user_a,
      name: "Chat",
      handle: SecureRandom.hex(8),
      collective_type: "chat",
      billing_exempt: true,
    )

    chat_collective.add_user!(user_a)
    chat_collective.add_user!(user_b) unless user_a.id == user_b.id

    create!(
      tenant: tenant,
      collective: chat_collective,
      user_one_id: user_one_id,
      user_two_id: user_two_id,
    )
  end
  private_class_method :create_with_chat_collective

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

  private

  sig { void }
  def collective_must_be_chat_type
    c = collective
    return unless c
    unless c.chat?
      errors.add(:collective, "must be a chat collective")
    end
  end

  sig { void }
  def participants_in_canonical_order
    if user_one_id.present? && user_two_id.present? && user_one_id > user_two_id
      errors.add(:user_one_id, "must be <= user_two_id (canonical order)")
    end
  end
end
