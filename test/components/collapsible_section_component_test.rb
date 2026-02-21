# typed: false

require "test_helper"

class CollapsibleSectionComponentTest < ViewComponent::TestCase
  test "renders with title and content" do
    render_inline(CollapsibleSectionComponent.new(title: "Section")) { "Body content" }
    assert_selector "[data-controller='collapseable-section']"
    assert_text "Section"
    assert_text "Body content"
  end

  test "renders with specified header level" do
    render_inline(CollapsibleSectionComponent.new(title: "Title", header_level: 3)) { "Body" }
    assert_selector "h3"
  end

  test "defaults to h1" do
    render_inline(CollapsibleSectionComponent.new(title: "Title")) { "Body" }
    assert_selector "h1"
  end

  test "renders expanded by default" do
    render_inline(CollapsibleSectionComponent.new(title: "Title")) { "Body" }
    assert_selector "[data-collapseable-section-target='triangleDown'][style*='display:inline']", visible: :all
    assert_selector "[data-collapseable-section-target='triangleRight'][style*='display:none']", visible: :all
  end

  test "renders collapsed when hidden is true" do
    render_inline(CollapsibleSectionComponent.new(title: "Title", hidden: true)) { "Body" }
    assert_selector "[data-collapseable-section-target='triangleRight'][style*='display:inline']", visible: :all
    assert_selector "[data-collapseable-section-target='triangleDown'][style*='display:none']", visible: :all
    assert_selector "[data-collapseable-section-target='body'][style*='display:none']", visible: :all
  end

  test "renders string title_superscript" do
    render_inline(CollapsibleSectionComponent.new(title: "Title", title_superscript: "5")) { "Body" }
    assert_selector ".header-superscript", text: "5"
  end

  test "renders hash title_superscript with strong for positive integers" do
    render_inline(CollapsibleSectionComponent.new(title: "Title", title_superscript: { "" => 3 })) { "Body" }
    assert_selector ".header-superscript strong", text: /3/
  end

  test "renders icon when provided" do
    render_inline(CollapsibleSectionComponent.new(title: "Title", icon: "pin")) { "Body" }
    assert_selector "svg"
  end

  test "renders indent style when indent is true" do
    render_inline(CollapsibleSectionComponent.new(title: "Title", indent: true)) { "Body" }
    assert_selector "[data-collapseable-section-target='body'][style*='padding-left:16px']", visible: :all
  end

  test "renders lazy load div with url" do
    render_inline(CollapsibleSectionComponent.new(title: "Title", lazy_load: "/load/content")) { "Body" }
    assert_selector "[data-collapseable-section-target='lazyLoad'][data-url='/load/content']", visible: :all
  end

  test "renders target data attributes" do
    render_inline(CollapsibleSectionComponent.new(title: "Title", target: { "my-controller" => "heading" })) { "Body" }
    assert_selector "[data-my-controller-target='heading']"
  end
end
