# typed: false

class AvatarComponent < ViewComponent::Base
  # Renders a user avatar with initials fallback and optional image.
  #
  # @param user [User] object with display_name, handle, image_url, and path methods
  # @param size [String, nil] CSS class suffix for size variant (e.g., "small", "large")
  # @param show_link [Boolean] whether to wrap in a link to user.path
  # @param title [String, nil] custom title attribute (defaults to user.display_name)
  # @param css_class [String] CSS class for the avatar container
  def initialize(user:, size: nil, show_link: false, title: nil, css_class: "pulse-author-avatar")
    super()
    @user = user
    @size = size
    @show_link = show_link
    @title = title || user&.display_name
    @css_class = css_class
  end

  def render?
    @user.present?
  end

  private

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

  def has_image?
    @user&.image_url.present? && @user.image_url != "/placeholder.png"
  end

  def avatar_class
    result = @css_class
    result += " pulse-avatar-#{@size}" if @size
    result
  end
end
