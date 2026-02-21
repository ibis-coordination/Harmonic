# typed: false

require "test_helper"

class MoreButtonComponentTest < ViewComponent::TestCase
  FakeStudio = Struct.new(:path, :is_scene, keyword_init: true) do
    def is_scene? = is_scene
  end

  FakeResource = Struct.new(:path, :shareable_link, keyword_init: true)

  setup do
    @studio = FakeStudio.new(path: "/s/my-studio", is_scene: false)
    @resource = FakeResource.new(path: "/n/abc123", shareable_link: "https://example.com/n/abc123")
  end

  test "renders more-button Stimulus controller" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: [], studio: @studio))
    assert_selector "[data-controller='more-button']"
  end

  test "renders plus menu with new resource links" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: [], studio: @studio))
    assert_selector "a[href='/s/my-studio/note']", text: "New Note", visible: :all
    assert_selector "a[href='/s/my-studio/decide']", text: "New Decision", visible: :all
    assert_selector "a[href='/s/my-studio/commit']", text: "New Commitment", visible: :all
  end

  test "hides plus menu for scenes" do
    scene = FakeStudio.new(path: "/s/scene", is_scene: true)
    render_inline(MoreButtonComponent.new(resource: @resource, options: [], studio: scene))
    assert_selector "[data-more-button-target='plus'][style*='display:none']", visible: :all
  end

  test "renders kebab button when options present" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["edit"], studio: @studio))
    assert_selector "[data-more-button-target='button'] svg"
  end

  test "does not render kebab icon when no options" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: [], studio: @studio))
    assert_no_selector "[data-more-button-target='button'] svg"
  end

  test "renders copy option with clipboard controller" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["copy"], studio: @studio))
    assert_selector "[data-controller='clipboard']"
    assert_selector "input[value='https://example.com/n/abc123']", visible: :all
  end

  test "renders edit option as link" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["edit"], studio: @studio))
    assert_selector "a[href='/n/abc123/edit']", text: "Edit"
  end

  test "renders settings option as link" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["settings"], studio: @studio))
    assert_selector "a[href='/n/abc123/settings']", text: "Settings"
  end

  test "renders divider option" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["---"], studio: @studio))
    assert_selector "hr"
  end

  test "renders pin option with correct label when not pinned" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["pin"], studio: @studio, is_pinned: false))
    assert_selector "[data-url='/n/abc123/pin']", text: /Pin to studio homepage/
  end

  test "renders pin option with unpin label when pinned" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["pin"], studio: @studio, is_pinned: true))
    assert_text /Unpin from studio homepage/
  end

  test "renders pin label with 'your profile' for main collective" do
    main = FakeStudio.new(path: "/s/main", is_scene: false)
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["pin"], studio: main, is_pinned: false, main_collective: main))
    assert_text /Pin to your profile/
  end

  test "renders duplicate option" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["duplicate"], studio: @studio))
    assert_text "Duplicate"
  end

  test "renders multiple options" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["copy", "edit", "---", "settings"], studio: @studio))
    assert_selector "[data-controller='clipboard']"
    assert_selector "a[href='/n/abc123/edit']", text: "Edit"
    assert_selector "hr"
    assert_selector "a[href='/n/abc123/settings']", text: "Settings"
  end
end
