# typed: false

require "test_helper"

class AuthorComponentTest < ViewComponent::TestCase
  FakeUser = Struct.new(:display_name, :handle, :image_url, :path, :parent, keyword_init: true) do
    def present? = true
    def ai_agent? = false
  end

  FakeAiAgent = Struct.new(:display_name, :handle, :image_url, :path, :parent, keyword_init: true) do
    def present? = true
    def ai_agent? = true
  end

  FakeResource = Struct.new(:created_by, :created_at, :updated_at, :updated_by, keyword_init: true) do
    def representative_user = nil
    def created_via_representation? = false
  end

  setup do
    @user = FakeUser.new(display_name: "Alice Smith", handle: "alice", image_url: nil, path: "/u/alice")
    @now = Time.current
  end

  test "renders author name and avatar" do
    resource = FakeResource.new(created_by: @user, created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-feed-item-author strong", text: "Alice Smith"
  end

  test "renders verb when provided" do
    resource = FakeResource.new(created_by: @user, created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource, verb: "posted"))
    assert_text "posted"
  end

  test "does not render verb when nil" do
    resource = FakeResource.new(created_by: @user, created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource))
    assert_no_text "posted"
  end

  test "does not render when display_author is nil" do
    resource = FakeResource.new(created_by: nil, created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource))
    assert_no_selector ".pulse-feed-item-author"
  end

  test "shows representation label when created via representation" do
    representative = FakeUser.new(display_name: "Bob Rep", handle: "bob", image_url: nil, path: "/u/bob")
    resource = FakeResource.new(created_by: @user, created_at: @now, updated_at: @now)
    resource.define_singleton_method(:representative_user) { representative }
    resource.define_singleton_method(:created_via_representation?) { true }
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-representation-label", text: /on behalf of/
    assert_selector "a[href='/u/alice']", text: "Alice Smith"
  end

  test "shows AI agent label when author is AI agent with parent" do
    owner = FakeUser.new(display_name: "Owner", handle: "owner", image_url: nil, path: "/u/owner")
    agent = FakeAiAgent.new(display_name: "Bot", handle: "bot", image_url: nil, path: "/u/bot", parent: owner)
    resource = FakeResource.new(created_by: agent, created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-ai-agent-label", text: /managed by/
    assert_selector "a[href='/u/owner']", text: "Owner"
  end

  test "shows updated info when updated more than 1 minute after creation" do
    resource = FakeResource.new(created_by: @user, created_at: 1.hour.ago, updated_at: Time.current)
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-feed-item-updated", text: /Updated/
  end

  test "does not show updated info when updated within 1 minute" do
    resource = FakeResource.new(created_by: @user, created_at: @now, updated_at: @now + 30.seconds)
    render_inline(AuthorComponent.new(resource: resource))
    assert_no_selector ".pulse-feed-item-updated"
  end

  test "shows updater name when different from author" do
    updater = FakeUser.new(display_name: "Charlie", handle: "charlie", image_url: nil, path: "/u/charlie")
    resource = FakeResource.new(created_by: @user, created_at: 1.hour.ago, updated_at: Time.current, updated_by: updater)
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-feed-item-updated a[href='/u/charlie']", text: "Charlie"
  end
end
