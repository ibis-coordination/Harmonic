# typed: true

class ProfilePicComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      user: User,
      size: Integer,
      style: String,
      show_parent: T::Boolean
    ).void
  end
  def initialize(user:, size: 30, style: "", show_parent: false)
    super()
    @user = user
    @size = size
    @style = style
    @show_parent = show_parent
  end

  sig { returns(T::Boolean) }
  def render?
    @user.present?
  end

  private

  sig { returns(T::Boolean) }
  def has_image?
    @user.image_url.present?
  end

  sig { returns(T::Boolean) }
  def parent_has_image?
    @user.parent&.image_url.present?
  end

  sig { returns(Symbol) }
  def size_variant
    return :icon if @size <= 48
    return :thumbnail if @size <= 200
    :display
  end

  sig { returns(Symbol) }
  def parent_size_variant
    # parent overlay is parent_size px; small, always :icon
    :icon
  end

  sig { returns(String) }
  def initials
    name = @user.display_name || @user.handle
    return "?" if name.blank?

    parts = name.to_s.split(/[\s\-_]+/)
    if parts.length >= 2
      "#{T.must(parts[0])[0]}#{T.must(parts[1])[0]}".upcase
    else
      T.must(name.to_s[0..1]).upcase
    end
  end

  sig { returns(String) }
  def fallback_style
    "background-color: #{@user.avatar_color};" \
      "width:#{@size}px;height:#{@size}px;" \
      "display:inline-flex;align-items:center;justify-content:center;" \
      "color:white;border-radius:50%;font-weight:600;font-size:#{(@size * 0.4).to_i}px;" \
      "#{@style}"
  end

  sig { returns(String) }
  def parent_initial
    parent = @user.parent
    return "?" unless parent
    name = parent.display_name || parent.handle
    return "?" if name.blank?
    T.must(name[0]).upcase
  end

  sig { returns(String) }
  def parent_fallback_style
    parent = T.must(@user.parent)
    "position:absolute;bottom:-2px;right:-2px;" \
      "width:#{parent_size}px;height:#{parent_size}px;" \
      "border:1px solid var(--color-border-default);" \
      "border-radius:50%;background-color:#{parent.avatar_color};" \
      "display:inline-flex;align-items:center;justify-content:center;" \
      "color:white;font-size:#{(parent_size * 0.5).to_i}px;font-weight:600;"
  end

  sig { returns(String) }
  def title
    parent = @user.parent
    if @user.ai_agent? && parent
      "#{@user.display_name} (ai_agent of #{parent.display_name})"
    else
      @user.display_name || ""
    end
  end

  sig { returns(T::Boolean) }
  def show_parent_overlay?
    @show_parent && @user.ai_agent? && @user.parent.present?
  end

  sig { returns(Integer) }
  def parent_size
    (@size * 0.4).to_i
  end
end
