# typed: true

class CopyButtonComponent < ViewComponent::Base
  extend T::Sig

  sig { params(text: String, message: T.nilable(String), success_message: T.nilable(String)).void }
  def initialize(text:, message: nil, success_message: nil)
    super()
    @text = text
    @message = message
    @success_message = success_message || message
  end
end
