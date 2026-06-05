# typed: false

require "test_helper"

class AjaxToggleButtonComponentTest < ViewComponent::TestCase
  def args(on:)
    {
      on: on,
      on_url: "/remove",
      on_html: "Remove",
      off_url: "/add",
      off_html: "Add",
    }
  end

  test "renders the ajax-toggle Stimulus controller" do
    render_inline(AjaxToggleButtonComponent.new(**args(on: false)))
    assert_selector "button[data-controller='ajax-toggle']"
    assert_selector "button[data-action='click->ajax-toggle#toggle']"
  end

  test "when off: renders off_html as content and stores on as alt" do
    render_inline(AjaxToggleButtonComponent.new(**args(on: false)))
    assert_text "Add"
    assert_no_text "Remove"
    assert_selector "button[data-ajax-toggle-url-value='/add']"
    assert_selector "button[data-ajax-toggle-alt-url-value='/remove']"
    assert_selector "button[data-ajax-toggle-alt-html-value='Remove']"
  end

  test "when on: renders on_html as content and stores off as alt" do
    render_inline(AjaxToggleButtonComponent.new(**args(on: true)))
    assert_text "Remove"
    assert_no_text "Add"
    assert_selector "button[data-ajax-toggle-url-value='/remove']"
    assert_selector "button[data-ajax-toggle-alt-url-value='/add']"
    assert_selector "button[data-ajax-toggle-alt-html-value='Add']"
  end

  test "accepts HTML-safe content and properly escapes it into the alt-html attribute" do
    on_html = "<svg></svg> On".html_safe
    off_html = "<svg></svg> Off".html_safe
    render_inline(AjaxToggleButtonComponent.new(
                    on: false, on_url: "/r", off_url: "/a",
                    on_html: on_html, off_html: off_html
                  ))
    button = page.find("button[data-controller='ajax-toggle']")
    assert_equal "<svg></svg> On", button["data-ajax-toggle-alt-html-value"]
    # And the visible content is the off_html (a real <svg>).
    assert_selector "button svg"
  end

  test "defaults to the secondary button class" do
    render_inline(AjaxToggleButtonComponent.new(**args(on: false)))
    assert_selector "button.pulse-action-btn-secondary"
  end

  test "honors a custom css_class" do
    render_inline(AjaxToggleButtonComponent.new(**args(on: false), css_class: "pulse-action-btn"))
    assert_selector "button.pulse-action-btn"
  end

  test "supports state-specific classes (on_class / off_class), applying the current one and storing the alt" do
    # off state — render off_class, store on_class as alt
    render_inline(AjaxToggleButtonComponent.new(**args(on: false),
                                                on_class: "pulse-action-btn-secondary",
                                                off_class: "pulse-action-btn"))
    assert_selector "button.pulse-action-btn"
    assert_no_selector "button.pulse-action-btn-secondary"
    button = page.find("button[data-controller='ajax-toggle']")
    assert_equal "pulse-action-btn-secondary", button["data-ajax-toggle-alt-class-value"]
  end

  test "state-specific classes flip when on:true" do
    render_inline(AjaxToggleButtonComponent.new(**args(on: true),
                                                on_class: "pulse-action-btn-secondary",
                                                off_class: "pulse-action-btn"))
    assert_selector "button.pulse-action-btn-secondary"
    assert_no_selector "button.pulse-action-btn"
    button = page.find("button[data-controller='ajax-toggle']")
    assert_equal "pulse-action-btn", button["data-ajax-toggle-alt-class-value"]
  end

  test "when no on_class/off_class, alt-class-value stays empty (no swap needed)" do
    render_inline(AjaxToggleButtonComponent.new(**args(on: false)))
    button = page.find("button[data-controller='ajax-toggle']")
    # Either empty or absent; both signal 'no class swap'.
    assert button["data-ajax-toggle-alt-class-value"].to_s.empty?
  end

  test "renders an optional title" do
    render_inline(AjaxToggleButtonComponent.new(**args(on: false), title: "Toggle me"))
    assert_selector "button[title='Toggle me']"
  end
end
