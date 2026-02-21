# typed: false

require "test_helper"
require_relative "component_test_helper"

class AvatarComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  setup do
    @user = build_user(display_name: "Alice Smith", handle: "alice")
  end

  test "renders initials from two-word name" do
    render_inline(AvatarComponent.new(user: @user))
    assert_selector ".pulse-avatar-initials", text: "AS"
  end

  test "renders initials from single-word name" do
    user = build_user(display_name: "Alice", handle: "alice")
    render_inline(AvatarComponent.new(user: user))
    assert_selector ".pulse-avatar-initials", text: "AL"
  end

  test "renders default css class" do
    render_inline(AvatarComponent.new(user: @user))
    assert_selector ".pulse-author-avatar"
  end

  test "renders with size class" do
    render_inline(AvatarComponent.new(user: @user, size: "small"))
    assert_selector ".pulse-avatar-small"
  end

  test "does not render when user is nil" do
    render_inline(AvatarComponent.new(user: nil))
    assert_no_selector ".pulse-author-avatar"
  end

  test "wraps in link when show_link is true" do
    render_inline(AvatarComponent.new(user: @user, show_link: true))
    assert_selector "a .pulse-author-avatar"
  end

  test "does not wrap in link when show_link is false" do
    render_inline(AvatarComponent.new(user: @user, show_link: false))
    assert_no_selector "a"
  end

  test "uses custom css_class" do
    render_inline(AvatarComponent.new(user: @user, css_class: "custom-avatar"))
    assert_selector ".custom-avatar"
    assert_no_selector ".pulse-author-avatar"
  end

  test "uses custom title" do
    render_inline(AvatarComponent.new(user: @user, title: "Custom Title"))
    assert_selector "[title='Custom Title']"
  end

  test "defaults title to user display_name" do
    render_inline(AvatarComponent.new(user: @user))
    assert_selector "[title='Alice Smith']"
  end

  test "renders image when user has image_url" do
    user = build_user(display_name: "Alice Smith", handle: "alice", image_url: "https://example.com/avatar.jpg")
    render_inline(AvatarComponent.new(user: user))
    assert_selector "img.pulse-avatar-img[src='https://example.com/avatar.jpg']"
  end

  test "does not render image when image_url is placeholder" do
    user = build_user(display_name: "Alice Smith", handle: "alice", image_url: "/placeholder.png")
    render_inline(AvatarComponent.new(user: user))
    assert_no_selector "img"
  end

  test "does not render image when image_url is blank" do
    render_inline(AvatarComponent.new(user: @user))
    assert_no_selector "img"
  end
end
