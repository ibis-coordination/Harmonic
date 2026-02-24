# typed: false

require "test_helper"
require_relative "component_test_helper"

class ProfilePicComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  test "renders image tag with default size" do
    user = build_user(display_name: "Alice", handle: "alice", image_url: "https://example.com/alice.jpg")
    render_inline(ProfilePicComponent.new(user: user))
    assert_selector "img.profile-pic[width='30'][height='30']"
    assert_selector "img[title='Alice']"
  end

  test "renders image tag with custom size" do
    user = build_user(display_name: "Alice", handle: "alice", image_url: "https://example.com/alice.jpg")
    render_inline(ProfilePicComponent.new(user: user, size: 20))
    assert_selector "img.profile-pic[width='20'][height='20']"
  end

  test "does not render when user has no image" do
    user = build_user(display_name: "Alice", handle: "alice", image_url: nil)
    render_inline(ProfilePicComponent.new(user: user))
    assert_no_selector "img"
  end

  test "renders AI agent title with parent attribution" do
    parent = build_user(display_name: "Owner", handle: "owner", image_url: nil)
    agent = build_user(display_name: "Bot", handle: "bot", image_url: "https://example.com/bot.jpg", user_type: "ai_agent", parent: parent)
    render_inline(ProfilePicComponent.new(user: agent))
    assert_selector "img[title='Bot (ai_agent of Owner)']"
  end

  test "renders parent overlay when show_parent is true" do
    parent = build_user(display_name: "Owner", handle: "owner", image_url: "https://example.com/owner.jpg")
    agent = build_user(display_name: "Bot", handle: "bot", image_url: "https://example.com/bot.jpg", user_type: "ai_agent", parent: parent)
    render_inline(ProfilePicComponent.new(user: agent, show_parent: true))
    assert_selector "img.profile-pic", count: 1
    assert_selector "img.profile-pic-parent", count: 1
    assert_selector "img.profile-pic-parent[title='Managed by Owner']"
  end

  test "does not render parent overlay when show_parent is false" do
    parent = build_user(display_name: "Owner", handle: "owner", image_url: "https://example.com/owner.jpg")
    agent = build_user(display_name: "Bot", handle: "bot", image_url: "https://example.com/bot.jpg", user_type: "ai_agent", parent: parent)
    render_inline(ProfilePicComponent.new(user: agent, show_parent: false))
    assert_selector "img.profile-pic", count: 1
    assert_no_selector "img.profile-pic-parent"
  end

  test "applies custom style" do
    user = build_user(display_name: "Alice", handle: "alice", image_url: "https://example.com/alice.jpg")
    render_inline(ProfilePicComponent.new(user: user, style: "vertical-align:bottom;"))
    assert_selector "img[style*='vertical-align:bottom;']"
  end
end
