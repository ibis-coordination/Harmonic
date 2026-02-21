# typed: false

require "test_helper"

class PinButtonComponentTest < ViewComponent::TestCase
  FakeResource = Struct.new(:path, keyword_init: true)

  setup do
    @resource = FakeResource.new(path: "/n/abc123")
  end

  test "renders pin Stimulus controller" do
    render_inline(PinButtonComponent.new(resource: @resource, is_pinned: false))
    assert_selector "[data-controller='pin']"
  end

  test "renders pin url from resource path" do
    render_inline(PinButtonComponent.new(resource: @resource, is_pinned: false))
    assert_selector "[data-pin-url='/n/abc123/pin']"
  end

  test "renders Pin label when not pinned" do
    render_inline(PinButtonComponent.new(resource: @resource, is_pinned: false))
    assert_selector "[data-pin-target='label']", text: "Pin"
  end

  test "renders Unpin label when pinned" do
    render_inline(PinButtonComponent.new(resource: @resource, is_pinned: true))
    assert_selector "[data-pin-target='label']", text: "Unpin"
  end

  test "shows pin icon and hides unpin icon when not pinned" do
    render_inline(PinButtonComponent.new(resource: @resource, is_pinned: false))
    assert_no_selector "[data-pin-target='iconPin'][style*='display:none']", visible: :all
    assert_selector "[data-pin-target='iconUnpin'][style*='display:none']", visible: :all
  end

  test "shows unpin icon and hides pin icon when pinned" do
    render_inline(PinButtonComponent.new(resource: @resource, is_pinned: true))
    assert_selector "[data-pin-target='iconPin'][style*='display:none']", visible: :all
    assert_no_selector "[data-pin-target='iconUnpin'][style*='display:none']", visible: :all
  end

  test "renders correct title when not pinned" do
    render_inline(PinButtonComponent.new(resource: @resource, is_pinned: false))
    assert_selector "[title='Click to pin']"
  end

  test "renders correct title when pinned" do
    render_inline(PinButtonComponent.new(resource: @resource, is_pinned: true))
    assert_selector "[title='Click to unpin']"
  end
end
