# typed: true

class AvatarComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      user: T.untyped,
      size: T.nilable(String),
      show_link: T::Boolean,
      title: T.nilable(String),
      css_class: String,
    ).void
  end
  def initialize(user:, size: nil, show_link: false, title: nil, css_class: "pulse-author-avatar")
    super()
    @user = user
    @size = size
    @show_link = show_link
    @title = title || user&.display_name
    @css_class = css_class
  end

  sig { returns(T::Boolean) }
  def render?
    @user.present?
  end

  private

  sig { returns(String) }
  def initials
    name = @user&.display_name || @user&.handle
    return "?" if name.blank?

    parts = name.to_s.split(/[\s\-_]+/)
    if parts.length >= 2
      "#{parts[0][0]}#{parts[1][0]}".upcase
    else
      name[0..1].upcase
    end
  end

  sig { returns(T::Boolean) }
  def has_image?
    @user&.image_url.present? && @user.image_url != "/placeholder.png"
  end

  sig { returns(String) }
  def avatar_class
    result = @css_class
    result += " pulse-avatar-#{@size}" if @size
    result
  end
end
