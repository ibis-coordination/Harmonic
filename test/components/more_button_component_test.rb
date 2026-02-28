# typed: false

require "test_helper"
require_relative "component_test_helper"

class MoreButtonComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  setup do
    @collective = build_collective(handle: "my-collective")
    @resource = build_note(truncated_id: "abc123")
  end

  test "renders more-button Stimulus controller" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: [], collective: @collective))
    assert_selector "[data-controller='more-button']"
  end

  test "renders plus menu with new resource links" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: [], collective: @collective))
    assert_selector "a[href='/s/my-collective/note']", text: "New Note", visible: :all
    assert_selector "a[href='/s/my-collective/decide']", text: "New Decision", visible: :all
    assert_selector "a[href='/s/my-collective/commit']", text: "New Commitment", visible: :all
  end

  test "renders kebab button when options present" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["edit"], collective: @collective))
    assert_selector "[data-more-button-target='button'] svg"
  end

  test "does not render kebab icon when no options" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: [], collective: @collective))
    assert_no_selector "[data-more-button-target='button'] svg"
  end

  test "renders copy option with clipboard controller" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["copy"], collective: @collective))
    assert_selector "[data-controller='clipboard']"
    assert_selector "input[value='https://example.com/n/abc123']", visible: :all
  end

  test "renders edit option as link" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["edit"], collective: @collective))
    assert_selector "a[href='/n/abc123/edit']", text: "Edit"
  end

  test "renders settings option as link" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["settings"], collective: @collective))
    assert_selector "a[href='/n/abc123/settings']", text: "Settings"
  end

  test "renders divider option" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["---"], collective: @collective))
    assert_selector "hr"
  end

  test "renders pin option with correct label when not pinned" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["pin"], collective: @collective, is_pinned: false))
    assert_selector "[data-url='/n/abc123/pin']", text: /Pin to collective homepage/
  end

  test "renders pin option with unpin label when pinned" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["pin"], collective: @collective, is_pinned: true))
    assert_text(/Unpin from collective homepage/)
  end

  test "renders pin label with 'your profile' for main collective" do
    main = build_collective(handle: "main")
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["pin"], collective: main, is_pinned: false, main_collective: main))
    assert_text(/Pin to your profile/)
  end

  test "renders duplicate option" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["duplicate"], collective: @collective))
    assert_text "Duplicate"
  end

  test "renders multiple options" do
    render_inline(MoreButtonComponent.new(resource: @resource, options: ["copy", "edit", "---", "settings"], collective: @collective))
    assert_selector "[data-controller='clipboard']"
    assert_selector "a[href='/n/abc123/edit']", text: "Edit"
    assert_selector "hr"
    assert_selector "a[href='/n/abc123/settings']", text: "Settings"
  end
end
