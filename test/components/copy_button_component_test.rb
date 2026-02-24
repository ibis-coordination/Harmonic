# typed: false

require "test_helper"

class CopyButtonComponentTest < ViewComponent::TestCase
  test "renders hidden input with text value" do
    render_inline(CopyButtonComponent.new(text: "https://example.com"))
    assert_selector "input[type='text'][value='https://example.com'][style='display:none;']", visible: :all
  end

  test "renders clipboard Stimulus controller" do
    render_inline(CopyButtonComponent.new(text: "hello"))
    assert_selector "[data-controller='clipboard']"
  end

  test "renders copy action button" do
    render_inline(CopyButtonComponent.new(text: "hello"))
    assert_selector "[data-action='click->clipboard#copy']"
  end

  test "renders message when provided" do
    render_inline(CopyButtonComponent.new(text: "hello", message: "Copy link"))
    assert_selector "[data-clipboard-target='button']", text: "Copy link"
  end

  test "renders success message defaulting to message" do
    render_inline(CopyButtonComponent.new(text: "hello", message: "Copy link"))
    assert_selector "[data-clipboard-target='successMessage']", text: "Copy link", visible: :all
  end

  test "renders custom success message" do
    render_inline(CopyButtonComponent.new(text: "hello", message: "Copy", success_message: "Copied!"))
    assert_selector "[data-clipboard-target='successMessage']", text: "Copied!", visible: :all
  end

  test "renders without message (icon-only)" do
    render_inline(CopyButtonComponent.new(text: "hello"))
    assert_selector "[data-clipboard-target='button']"
  end
end
