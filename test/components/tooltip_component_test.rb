# typed: false

require "test_helper"

class TooltipComponentTest < ViewComponent::TestCase
  test "renders tooltip container with Stimulus controller" do
    render_inline(TooltipComponent.new) { "Help text" }
    assert_selector ".tooltip[data-controller='tooltip']"
  end

  test "renders block content inside tooltip info" do
    render_inline(TooltipComponent.new) { "Help text" }
    assert_selector ".tooltip-info", text: "Help text", visible: :all
  end

  test "renders close button target" do
    render_inline(TooltipComponent.new) { "Help text" }
    assert_selector "[data-tooltip-target='x']", visible: :all
  end

  test "renders info target" do
    render_inline(TooltipComponent.new) { "Help text" }
    assert_selector "[data-tooltip-target='info']", visible: :all
  end
end
