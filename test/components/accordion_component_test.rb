# typed: false

require "test_helper"

class AccordionComponentTest < ViewComponent::TestCase
  test "renders with title and content" do
    render_inline(AccordionComponent.new(title: "Details", open: true)) { "Body content" }
    assert_selector ".pulse-accordion"
    assert_selector ".pulse-accordion-header", text: "Details"
    assert_selector ".pulse-accordion-content", text: "Body content"
  end

  test "renders closed by default" do
    render_inline(AccordionComponent.new(title: "Details")) { "Body" }
    assert_no_selector "details[open]"
  end

  test "renders open when open is true" do
    render_inline(AccordionComponent.new(title: "Details", open: true)) { "Body" }
    assert_selector "details[open]"
  end

  test "renders count when provided" do
    render_inline(AccordionComponent.new(title: "Items", count: 5)) { "Body" }
    assert_selector ".pulse-accordion-count", text: "(5)"
  end

  test "does not render count when nil" do
    render_inline(AccordionComponent.new(title: "Items")) { "Body" }
    assert_no_selector ".pulse-accordion-count"
  end

  test "renders icon when provided" do
    render_inline(AccordionComponent.new(title: "Details", icon: "eye")) { "Body" }
    assert_selector ".pulse-accordion-title-icon"
  end

  test "does not render icon when nil" do
    render_inline(AccordionComponent.new(title: "Details")) { "Body" }
    assert_no_selector ".pulse-accordion-title-icon"
  end

  test "renders tooltip as title attribute" do
    render_inline(AccordionComponent.new(title: "Details", tooltip: "More info")) { "Body" }
    assert_selector ".pulse-accordion-title[title='More info']"
  end

  test "renders data attributes on title" do
    render_inline(AccordionComponent.new(
                    title: "Details",
                    title_data: { "decision-results-target" => "header" }
                  )) { "Body" }
    assert_selector "[data-decision-results-target='header']"
  end

  test "renders chevron icon" do
    render_inline(AccordionComponent.new(title: "Details")) { "Body" }
    assert_selector ".pulse-accordion-icon"
  end
end
