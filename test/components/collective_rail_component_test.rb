# typed: false

require "test_helper"
require_relative "component_test_helper"

class CollectiveRailComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  # Build a rail-ready collective: build_collective plus the extra methods the
  # rail template touches (path, avatar_color, image_url).
  def build_rail_collective(name:, handle:, path: "/collectives/#{handle}")
    collective = build_collective(name: name, handle: handle)
    collective.define_singleton_method(:path) { path }
    collective.define_singleton_method(:avatar_color) { "#336699" }
    collective.define_singleton_method(:image_url) { |**| nil }
    collective
  end

  def main_collective
    build_rail_collective(name: "Public", handle: "public", path: nil)
  end

  test "renders the public space as a bare eye with no square avatar" do
    render_inline(CollectiveRailComponent.new(main_collective: main_collective, collectives: []))

    assert_selector "a.pulse-rail-public[href='/']"
    assert_selector ".pulse-rail-public .pulse-rail-eye .octicon"
    # The public entry is the ONLY one without a square avatar.
    assert_no_selector ".pulse-rail-public .pulse-rail-avatar"
  end

  test "renders a square avatar for each collective the viewer belongs to" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    b = build_rail_collective(name: "Team B", handle: "team-b")
    render_inline(CollectiveRailComponent.new(main_collective: main_collective, collectives: [a, b]))

    assert_selector "a.pulse-rail-item[href='/collectives/team-a'] .pulse-rail-avatar"
    assert_selector "a.pulse-rail-item[href='/collectives/team-b'] .pulse-rail-avatar"
  end

  test "renders a hidden unread badge on each rail entry when there are no unread counts" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    a.id = "11111111-1111-1111-1111-111111111111"
    main = main_collective
    main.id = "22222222-2222-2222-2222-222222222222"
    render_inline(CollectiveRailComponent.new(main_collective: main, collectives: [a]))

    assert_selector "a.pulse-rail-item[href='/collectives/team-a'] .pulse-rail-badge[data-collective-id='#{a.id}']",
                    visible: :hidden
    # The public space is a place like any other — its unread count badges
    # the eye, keyed to the main collective.
    assert_selector ".pulse-rail-public .pulse-rail-badge[data-collective-id='#{main.id}']", visible: :hidden
  end

  test "renders unread counts into the badges server-side so navigation never flashes them out" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    a.id = "11111111-1111-1111-1111-111111111111"
    b = build_rail_collective(name: "Team B", handle: "team-b")
    b.id = "33333333-3333-3333-3333-333333333333"
    main = main_collective
    main.id = "22222222-2222-2222-2222-222222222222"

    render_inline(CollectiveRailComponent.new(
                    main_collective: main,
                    collectives: [a, b],
                    unread_counts: { a.id => 4, main.id => 150 },
                  ))

    assert_selector ".pulse-rail-badge[data-collective-id='#{a.id}']", visible: :visible, text: "4"
    assert_selector ".pulse-rail-public .pulse-rail-badge[data-collective-id='#{main.id}']", visible: :visible, text: "99+"
    assert_selector ".pulse-rail-badge[data-collective-id='#{b.id}']", visible: :hidden
  end

  test "marks a collective active on its own page" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    b = build_rail_collective(name: "Team B", handle: "team-b")
    render_inline(CollectiveRailComponent.new(
                    main_collective: main_collective, collectives: [a, b], current_path: "/collectives/team-a"
                  ))

    assert_selector "a.pulse-rail-item.active[href='/collectives/team-a'][aria-current='page']"
    assert_no_selector "a.pulse-rail-item.active[href='/collectives/team-b']"
    assert_no_selector ".pulse-rail-public.active"
  end

  test "marks a collective active on its subpages" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    render_inline(CollectiveRailComponent.new(
                    main_collective: main_collective, collectives: [a], current_path: "/collectives/team-a/cycles/3"
                  ))

    assert_selector "a.pulse-rail-item.active[href='/collectives/team-a']"
  end

  test "does not mark a collective active for a sibling path sharing its prefix" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    render_inline(CollectiveRailComponent.new(
                    main_collective: main_collective, collectives: [a], current_path: "/collectives/team-alpha"
                  ))

    assert_no_selector ".pulse-rail-item.active"
  end

  test "marks the public space active only at the root path" do
    render_inline(CollectiveRailComponent.new(
                    main_collective: main_collective, collectives: [], current_path: "/"
                  ))
    assert_selector ".pulse-rail-public.active[aria-current='page']"

    render_inline(CollectiveRailComponent.new(
                    main_collective: main_collective, collectives: [], current_path: "/billing"
                  ))
    assert_no_selector ".pulse-rail-public.active"
  end

  test "omits aria-current entirely on inactive entries" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    render_inline(CollectiveRailComponent.new(
                    main_collective: main_collective, collectives: [a], current_path: "/billing"
                  ))

    assert_no_selector "[aria-current]"
  end

  test "skips collectives without a path instead of rendering an empty link" do
    unroutable = build_rail_collective(name: "Team A", handle: "team-a", path: nil)
    b = build_rail_collective(name: "Team B", handle: "team-b")
    render_inline(CollectiveRailComponent.new(main_collective: main_collective, collectives: [unroutable, b]))

    assert_selector "a.pulse-rail-item[href='/collectives/team-b']"
    assert_no_selector "a[title='Team A']"
  end

  test "renders a + entry at the rail bottom linking to the collectives browser" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    render_inline(CollectiveRailComponent.new(main_collective: main_collective, collectives: [a]))

    assert_selector "a.pulse-rail-add[href='/collectives'][title='Create or join a collective']"
    assert_selector ".pulse-rail-add .octicon"
  end

  test "the + entry never takes an active state — /collectives is not a place" do
    render_inline(CollectiveRailComponent.new(
                    main_collective: main_collective, collectives: [], current_path: "/collectives"
                  ))

    assert_selector "a.pulse-rail-add[href='/collectives']"
    assert_no_selector ".pulse-rail-add.active"
    assert_no_selector "[aria-current]"
  end

  test "omits the public space entry when no main collective is given" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    render_inline(CollectiveRailComponent.new(main_collective: nil, collectives: [a]))

    assert_no_selector ".pulse-rail-public"
    assert_no_selector ".pulse-rail-divider"
    assert_selector "a.pulse-rail-item[href='/collectives/team-a']"
  end

  test "renders nothing when there is no main collective and no collectives" do
    render_inline(CollectiveRailComponent.new(main_collective: nil, collectives: []))

    assert_no_selector ".pulse-rail"
  end
end
