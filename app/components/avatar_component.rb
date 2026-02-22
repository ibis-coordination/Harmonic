# typed: true

class AvatarComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      user: T.nilable(User),
      size: T.nilable(String),
      show_link: T::Boolean,
      title: T.nilable(String),
      css_class: String
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
      "#{T.must(parts[0])[0]}#{T.must(parts[1])[0]}".upcase
    else
      T.must(name.to_s[0..1]).upcase
    end
  end

  sig { returns(T::Boolean) }
  def has_image?
    url = @user&.image_url
    url.present? && url != "/placeholder.png"
  end

  sig { returns(String) }
  def avatar_class
    result = @css_class
    result += " pulse-avatar-#{@size}" if @size
    result
  end
end
