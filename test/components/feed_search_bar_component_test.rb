# typed: false

require "test_helper"

class FeedSearchBarComponentTest < ViewComponent::TestCase
  test "renders a GET form with the query prefilled" do
    render_inline(FeedSearchBarComponent.new(action: "/search", query: "type:note budget"))

    assert_selector "form[action='/search'][method='get']"
    assert_selector "input[name='q'][value='type:note budget']"
  end

  test "renders fixed scope filters as locked chips outside the input" do
    render_inline(FeedSearchBarComponent.new(action: "/collectives/my-team/feed", scope_filters: ["collective:my-team"]))

    assert_selector ".pulse-feed-bar-scope", count: 1
    assert_selector ".pulse-feed-bar-scope code", text: "collective:my-team"
    assert_selector ".pulse-feed-bar-scope .octicon-lock"
    # The fixed scope is not part of the editable input.
    assert_no_selector "input[value*='collective:my-team']"
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
