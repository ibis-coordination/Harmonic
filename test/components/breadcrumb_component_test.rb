# typed: false

require "test_helper"

class BreadcrumbComponentTest < ViewComponent::TestCase
  test "renders link items as anchors" do
    render_inline(BreadcrumbComponent.new(items: [["Home", "/"], "Current"]))
    assert_selector "a[href='/']", text: "Home"
  end

  test "renders string items as spans" do
    render_inline(BreadcrumbComponent.new(items: [["Home", "/"], "Current"]))
    assert_selector "span", text: "Current"
  end

  test "renders separators between items" do
    render_inline(BreadcrumbComponent.new(items: [["Home", "/"], ["Middle", "/mid"], "End"]))
    assert_selector ".pulse-breadcrumb-sep", count: 2
  end

  test "does not render separator after last item" do
    render_inline(BreadcrumbComponent.new(items: ["Only"]))
    assert_no_selector ".pulse-breadcrumb-sep"
  end

  test "renders nav with aria-label" do
    render_inline(BreadcrumbComponent.new(items: ["Page"]))
    assert_selector "nav.pulse-breadcrumb[aria-label='Breadcrumb']"
  end

  test "renders multiple link items" do
    render_inline(BreadcrumbComponent.new(items: [["Home", "/"], ["Studio", "/s/abc"], "Note"]))
    assert_selector "a", count: 2
    assert_selector "a[href='/s/abc']", text: "Studio"
  end
end
