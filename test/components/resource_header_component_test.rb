# typed: false

require "test_helper"
require_relative "component_test_helper"

class ResourceHeaderComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  test "renders title in h1" do
    render_inline(ResourceHeaderComponent.new(type_label: "Note", title: "My Note"))
    assert_selector "h1.pulse-resource-title", text: "My Note"
  end

  test "renders octicon icon when icon_name provided" do
    render_inline(ResourceHeaderComponent.new(type_label: "Comment", title: "Title", icon_name: "comment"))
    assert_selector ".pulse-resource-type-label .octicon"
  end

  test "renders CSS icon when icon_class provided" do
    render_inline(ResourceHeaderComponent.new(type_label: "Note", title: "Title", icon_class: "note-icon"))
    assert_selector "i.note-icon.icon-sm"
  end

  test "renders open status badge" do
    render_inline(ResourceHeaderComponent.new(type_label: "Decision", title: "Title", status: "open"))
    assert_selector ".pulse-status-badge.pulse-status-open", text: "Open"
  end

  test "renders closed status badge" do
    render_inline(ResourceHeaderComponent.new(type_label: "Decision", title: "Title", status: "closed"))
    assert_selector ".pulse-status-badge.pulse-status-closed", text: "Closed"
  end

  test "does not render status badge when nil" do
    render_inline(ResourceHeaderComponent.new(type_label: "Note", title: "Title"))
    assert_no_selector ".pulse-status-badge"
  end

  test "renders actions slot content" do
    render_inline(ResourceHeaderComponent.new(type_label: "Note", title: "Title")) do |header|
      header.with_actions { "<button>Edit</button>".html_safe }
    end
    assert_selector ".pulse-resource-actions button", text: "Edit"
  end

  test "renders type label text" do
    render_inline(ResourceHeaderComponent.new(type_label: "Representation Session", title: "Title", icon_name: "person"))
    assert_selector ".pulse-resource-type-label", text: /Representation Session/
  end
end
