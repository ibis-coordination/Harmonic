# typed: false

require "test_helper"
require_relative "component_test_helper"

class CollectiveRailComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  # Build a rail-ready collective: build_collective plus the extra methods the
  # rail template touches (id, avatar_color, image_url, is_main_collective?).
  def build_rail_collective(name:, handle:, id: SecureRandom.uuid, is_main: false)
    collective = build_collective(name: name, handle: handle)
    collective.define_singleton_method(:id) { id }
    collective.define_singleton_method(:path) { "/collectives/#{handle}" }
    collective.define_singleton_method(:avatar_color) { "#336699" }
    collective.define_singleton_method(:image_url) { |variant: nil| nil }
    collective.define_singleton_method(:is_main_collective?) { is_main }
    collective
  end

  test "renders the public space as a bare eye with no square avatar" do
    main = build_rail_collective(name: "Public", handle: "public", is_main: true)
    render_inline(CollectiveRailComponent.new(main_collective: main, collectives: []))

    assert_selector "a.pulse-rail-public[href='/']"
    assert_selector ".pulse-rail-public .pulse-rail-eye .octicon"
    # The public entry is the ONLY one without a square avatar.
    assert_no_selector ".pulse-rail-public .pulse-rail-avatar"
  end

  test "renders a square avatar for each collective the viewer belongs to" do
    main = build_rail_collective(name: "Public", handle: "public", is_main: true)
    a = build_rail_collective(name: "Team A", handle: "team-a")
    b = build_rail_collective(name: "Team B", handle: "team-b")
    render_inline(CollectiveRailComponent.new(main_collective: main, collectives: [a, b]))

    assert_selector "a.pulse-rail-item[href='/collectives/team-a'] .pulse-rail-avatar"
    assert_selector "a.pulse-rail-item[href='/collectives/team-b'] .pulse-rail-avatar"
  end

  test "marks the current collective active" do
    main = build_rail_collective(name: "Public", handle: "public", is_main: true)
    a = build_rail_collective(name: "Team A", handle: "team-a", id: "a-id")
    b = build_rail_collective(name: "Team B", handle: "team-b", id: "b-id")
    current = build_rail_collective(name: "Team A", handle: "team-a", id: "a-id")

    render_inline(CollectiveRailComponent.new(main_collective: main, collectives: [a, b], current_collective: current))

    assert_selector "a.pulse-rail-item.active[href='/collectives/team-a']"
    assert_no_selector "a.pulse-rail-item.active[href='/collectives/team-b']"
    assert_no_selector ".pulse-rail-public.active"
  end

  test "marks the public space active on the main collective" do
    main = build_rail_collective(name: "Public", handle: "public", id: "main-id", is_main: true)
    current = build_rail_collective(name: "Public", handle: "public", id: "main-id", is_main: true)

    render_inline(CollectiveRailComponent.new(main_collective: main, collectives: [], current_collective: current))

    assert_selector ".pulse-rail-public.active"
  end

  test "marks the public space active when there is no collective context" do
    main = build_rail_collective(name: "Public", handle: "public", is_main: true)
    render_inline(CollectiveRailComponent.new(main_collective: main, collectives: [], current_collective: nil))

    assert_selector ".pulse-rail-public.active"
  end

  test "omits the public space entry when no main collective is given" do
    a = build_rail_collective(name: "Team A", handle: "team-a")
    render_inline(CollectiveRailComponent.new(main_collective: nil, collectives: [a]))

    assert_no_selector ".pulse-rail-public"
    assert_no_selector ".pulse-rail-divider"
    assert_selector "a.pulse-rail-item[href='/collectives/team-a']"
  end
end
