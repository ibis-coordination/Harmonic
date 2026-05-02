# typed: true

class ChatMessage < ApplicationRecord
  extend T::Sig

  belongs_to :tenant
  belongs_to :chat_session
  belongs_to :sender, class_name: "User"

  validates :content, presence: true
end
