# typed: false

require "test_helper"

class ResourceLinkComponentTest < ViewComponent::TestCase
  test "renders link from hash resource" do
    resource = { type: "Note", path: "/n/abc123", title: "My Note" }
    render_inline(ResourceLinkComponent.new(resource: resource))
    assert_selector ".pulse-resource-link"
    assert_selector "a.pulse-resource-title[href='/n/abc123']", text: "My Note"
    assert_selector "i.note-icon"
  end

  test "renders link from model-like object" do
    resource = Struct.new(:path, :title, keyword_init: true).new(path: "/d/xyz789", title: "My Decision")
    # stub class name
    resource.define_singleton_method(:class) { Struct.new(:to_s).new("Decision") }
    render_inline(ResourceLinkComponent.new(resource: resource))
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
