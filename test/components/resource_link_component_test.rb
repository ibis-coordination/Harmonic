# typed: false

require "test_helper"
require_relative "component_test_helper"

class ResourceLinkComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  test "renders link from hash resource" do
    resource = { type: "Note", path: "/n/abc123", title: "My Note" }
    render_inline(ResourceLinkComponent.new(resource: resource))
    assert_selector ".pulse-resource-link"
    assert_selector "a.pulse-resource-title[href='/n/abc123']", text: "My Note"
    assert_selector "i.note-icon"
  end

  test "renders link from model-like object" do
    decision = Decision.new(truncated_id: "xyz789")
    decision.define_singleton_method(:title) { "My Decision" }
    decision.define_singleton_method(:path) { "/d/xyz789" }
    render_inline(ResourceLinkComponent.new(resource: decision))
    assert_selector "a.pulse-resource-title[href='/d/xyz789']", text: "My Decision"
    assert_selector "i.decision-icon"
  end

  test "renders metric when hash resource has metric_value" do
    resource = {
      type: "Note",
      path: "/n/abc",
      title: "Title",
      metric_value: 5,
      metric_name: "votes",
      octicon_metric_icon_name: "thumbsup",
    }
    render_inline(ResourceLinkComponent.new(resource: resource))
    assert_selector ".pulse-resource-metric", text: /5/
  end

  test "does not render metric when absent" do
    resource = { type: "Note", path: "/n/abc", title: "Title" }
    render_inline(ResourceLinkComponent.new(resource: resource))
    assert_no_selector ".pulse-resource-metric"
  end

  test "defaults type to note when hash has no type" do
    resource = { path: "/n/abc", title: "Title" }
    render_inline(ResourceLinkComponent.new(resource: resource))
    assert_selector "i.note-icon"
  end
end
