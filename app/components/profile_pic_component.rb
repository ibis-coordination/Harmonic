# typed: true

class ProfilePicComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      user: User,
      size: Integer,
      style: String,
      show_parent: T::Boolean,
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
    @user.image_url.present?
  end

  private

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
    @show_parent && @user.ai_agent? && @user.parent&.image_url.present?
  end

  sig { returns(Integer) }
  def parent_size
    (@size * 0.4).to_i
  end
end
