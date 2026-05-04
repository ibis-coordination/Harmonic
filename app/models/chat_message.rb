# typed: true

class ChatMessage < ApplicationRecord
  extend T::Sig

  include Tracked

  belongs_to :tenant
  belongs_to :collective
  belongs_to :chat_session
  belongs_to :sender, class_name: "User"

  validates :content, presence: true
  validate :collective_matches_chat_session

  # Tracked uses created_by for the event actor; ChatMessage uses sender
  sig { returns(T.nilable(User)) }
  def created_by
    sender
  end

  private

  sig { void }
  def collective_matches_chat_session
    cs = chat_session
    return unless cs
    if collective_id != cs.collective_id
      errors.add(:collective, "must match the chat session's collective")
    end
  end
end
