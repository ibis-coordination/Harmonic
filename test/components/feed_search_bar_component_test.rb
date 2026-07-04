# typed: false

require "test_helper"

class FeedSearchBarComponentTest < ViewComponent::TestCase
  test "renders a GET form with the query prefilled" do
    render_inline(FeedSearchBarComponent.new(action: "/search", query: "type:note budget"))

    assert_selector "form[action='/search'][method='get']"
    assert_selector "textarea[name='q']", text: "type:note budget"
  end

  test "the query field is a one-row textarea that grows instead of scrolling horizontally" do
    render_inline(FeedSearchBarComponent.new(action: "/search", query: "type:note budget"))

    # A single-line <input> hides overflow behind horizontal scroll —
    # long defaults like `-subtype:comment` would be invisible. The
    # feed-bar-input controller grows the textarea and keeps Enter as
    # submit.
    assert_selector "textarea[name='q'][rows='1'][data-controller='feed-bar-input']"
    assert_selector "textarea[name='q'][data-action*='input->feed-bar-input#resize']"
    assert_selector "textarea[name='q'][data-action*='feed-bar-input#keydown']"
    # Re-fit when the viewport changes — wrapped line count depends on width.
    assert_selector "textarea[name='q'][data-action*='resize@window->feed-bar-input#resize']"
  end

  test "renders fixed scope filters as non-editable tokens inside the query field" do
    render_inline(FeedSearchBarComponent.new(action: "/collectives/my-team/feed", scope_filters: ["collective:my-team"]))

    # The fixed filter is part of the query visually — inside the same
    # field as the text input — but not part of the editable text.
    assert_selector ".pulse-feed-bar-field .pulse-feed-bar-scope code", text: "collective:my-team"
    assert_selector ".pulse-feed-bar-field textarea[name='q']"
    assert_no_selector "textarea[name='q']", text: "collective:my-team"
    assert_no_selector ".octicon-lock"
  end

  test "renders no chips when there is no fixed scope" do
    render_inline(FeedSearchBarComponent.new(action: "/search"))

    assert_no_selector ".pulse-feed-bar-scope"
  end

  test "renders warnings" do
    render_inline(FeedSearchBarComponent.new(
                    action: "/search",
                    warnings: ["visibility:bogus is not a valid visibility: filter"]
                  ))

    assert_selector ".pulse-feed-bar-warning", count: 1
    assert_selector ".pulse-feed-bar-warning", text: /visibility:bogus/
  end

  test "renders no warnings row when there are none" do
    render_inline(FeedSearchBarComponent.new(action: "/search"))

    assert_no_selector ".pulse-feed-bar-warning"
  end
end
