# typed: false

require "test_helper"
require_relative "component_test_helper"

class PlacesSheetComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  def build_sheet_collective(name:, handle:, path: "/collectives/#{handle}")
    collective = build_collective(name: name, handle: handle)
    collective.define_singleton_method(:path) { path }
    collective.define_singleton_method(:avatar_color) { "#336699" }
    collective.define_singleton_method(:image_url) { |**| nil }
    collective
  end

  def main_collective
    build_sheet_collective(name: "Public", handle: "public", path: nil)
  end

  test "renders every place destination as a labeled row" do
    a = build_sheet_collective(name: "Team A", handle: "team-a")
    render_inline(PlacesSheetComponent.new(main_collective: main_collective, collectives: [a]))

    assert_selector ".pulse-places-sheet a[href='/'] .octicon-globe"
    assert_selector ".pulse-places-sheet a[href='/']", text: "Public space"
    assert_selector ".pulse-places-sheet a[href='/chat'] .octicon-comment-discussion"
    assert_selector ".pulse-places-sheet a[href='/chat']", text: "Chat"
    assert_selector ".pulse-places-sheet a[href='/collectives/team-a']", text: "Team A"
    assert_selector ".pulse-places-sheet a[href='/collectives']", text: "Create or join a collective"
  end

  test "renders the per-cycle check-in heart on each collective row, filled when checked in" do
    checked_in = build_sheet_collective(name: "Team A", handle: "team-a")
    checked_in.define_singleton_method(:has_heartbeat) { true }
    pending = build_sheet_collective(name: "Team B", handle: "team-b")
    # pending.has_heartbeat defaults to false

    render_inline(PlacesSheetComponent.new(main_collective: main_collective, collectives: [checked_in, pending]))

    assert_selector ".pulse-places-sheet a[href='/collectives/team-a'] .pulse-heartbeat-sent .octicon-heart-fill"
    assert_selector ".pulse-places-sheet a[href='/collectives/team-b'] .pulse-heartbeat-pending .octicon-heart"
    # The public-space globe is not a check-in collective — no heart there.
    assert_no_selector ".pulse-places-sheet a[href='/'] .pulse-heartbeat-icon"
  end

  test "omits the chat row when show_chat is false (representation)" do
    a = build_sheet_collective(name: "Team A", handle: "team-a")
    render_inline(PlacesSheetComponent.new(main_collective: main_collective, collectives: [a], show_chat: false))

    # Chat is hidden while representing; every other destination still renders.
    assert_no_selector ".pulse-places-sheet a[href='/chat']"
    assert_selector ".pulse-places-sheet a[href='/']", text: "Public space"
    assert_selector ".pulse-places-sheet a[href='/collectives/team-a']", text: "Team A"
  end

  test "is closed by default and marked as a places-sheet panel target" do
    render_inline(PlacesSheetComponent.new(main_collective: main_collective, collectives: []))

    assert_selector ".pulse-places-sheet[data-places-sheet-target='panel'][aria-hidden='true']", visible: :all
    assert_selector "[data-places-sheet-target='backdrop']", visible: :all
  end

  test "renders unread badges server-side with the same keys the poller broadcast uses" do
    a = build_sheet_collective(name: "Team A", handle: "team-a")
    a.id = "11111111-1111-1111-1111-111111111111"
    main = main_collective
    main.id = "22222222-2222-2222-2222-222222222222"

    render_inline(PlacesSheetComponent.new(
                    main_collective: main,
                    collectives: [a],
                    unread_counts: { a.id => 4 },
                    chat_unread_count: 2,
                  ))

    assert_selector ".pulse-places-sheet .pulse-places-badge[data-collective-id='#{a.id}']", text: "4", visible: :all
    assert_selector ".pulse-places-sheet .pulse-places-badge[data-chat-badge]", text: "2", visible: :all
    assert_selector ".pulse-places-sheet .pulse-places-badge[data-collective-id='#{main.id}']", text: "", visible: :all
    # The badge sits to the left of the always-present heart, so a hidden badge
    # (zero count) lets that column collapse without shifting the right-aligned
    # heart column. Assert the heart is the badge's immediately-following sibling.
    assert_selector ".pulse-places-sheet .pulse-places-badge[data-collective-id='#{a.id}'] + .pulse-heartbeat-icon",
                    visible: :all
    # A second places-badges controller instance keeps these fresh after polls.
    assert_selector ".pulse-places-sheet [data-controller~='places-badges']", visible: :all
  end

  test "a badged row links to the place's feed filtered to what you were notified about" do
    a = build_sheet_collective(name: "Team A", handle: "team-a")
    a.id = "11111111-1111-1111-1111-111111111111"
    main = main_collective
    main.id = "22222222-2222-2222-2222-222222222222"

    render_inline(PlacesSheetComponent.new(
                    main_collective: main,
                    collectives: [a],
                    unread_counts: { a.id => 4 },
                    chat_unread_count: 2,
                  ))

    assert_selector ".pulse-places-sheet a[href='/collectives/team-a?q=my:notified'][data-place-path='/collectives/team-a']",
                    visible: :all
    # The globe has no unread here, so it links plainly — but still carries
    # the base path for live href swaps.
    assert_selector ".pulse-places-sheet a[href='/'][data-place-path='/']", visible: :all
    # Chat is not a feed — badge or not, its link never swaps.
    assert_selector ".pulse-places-sheet a[href='/chat']", visible: :all
    assert_no_selector ".pulse-places-sheet a[href='/chat'][data-place-path]", visible: :all
  end

  test "marks the current place active" do
    a = build_sheet_collective(name: "Team A", handle: "team-a")
    b = build_sheet_collective(name: "Team B", handle: "team-b")

    render_inline(PlacesSheetComponent.new(
                    main_collective: main_collective, collectives: [a, b], current_path: "/collectives/team-a/cycles/3"
                  ))
    assert_selector "a.pulse-places-row.active[href='/collectives/team-a'][aria-current='page']"
    assert_no_selector "a.pulse-places-row.active[href='/collectives/team-b']"

    render_inline(PlacesSheetComponent.new(
                    main_collective: main_collective, collectives: [a], current_path: "/"
                  ))
    assert_selector "a.pulse-places-row.active[href='/'][aria-current='page']"

    render_inline(PlacesSheetComponent.new(
                    main_collective: main_collective, collectives: [a], current_path: "/chat/somebody"
                  ))
    assert_selector "a.pulse-places-row.active[href='/chat'][aria-current='page']"

    # Sibling path prefixes and you-level pages activate nothing.
    render_inline(PlacesSheetComponent.new(
                    main_collective: main_collective, collectives: [a], current_path: "/collectives/team-alpha"
                  ))
    assert_no_selector ".pulse-places-row.active"
    render_inline(PlacesSheetComponent.new(
                    main_collective: main_collective, collectives: [a], current_path: "/billing"
                  ))
    assert_no_selector ".pulse-places-row.active"
    assert_no_selector "[aria-current]"
  end

  test "skips collectives without a path" do
    unroutable = build_sheet_collective(name: "No Path", handle: "no-path", path: nil)
    render_inline(PlacesSheetComponent.new(main_collective: main_collective, collectives: [unroutable]))

    assert_no_selector "a", text: "No Path"
  end

  test "renders nothing without a main collective or collectives" do
    render_inline(PlacesSheetComponent.new(main_collective: nil, collectives: []))

    assert_no_selector ".pulse-places-sheet", visible: :all
  end
end
