# typed: false

require "test_helper"
require_relative "component_test_helper"

class AuthorComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  setup do
    @user = build_user(display_name: "Alice Smith", handle: "alice")
    @now = Time.current
  end

  test "renders author name and avatar" do
    resource = build_note(created_by: @user, created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-feed-item-author strong", text: "Alice Smith"
  end

  test "renders verb when provided" do
    resource = build_note(created_by: @user, created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource, verb: "posted"))
    assert_text "posted"
  end

  test "does not render verb when nil" do
    resource = build_note(created_by: @user, created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource))
    assert_no_text "posted"
  end

  test "does not render when display_author is nil" do
    resource = build_note(created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource))
    assert_no_selector ".pulse-feed-item-author"
  end

  test "shows representation label when created via representation" do
    representative = build_user(display_name: "Bob Rep", handle: "bob")
    resource = build_note(created_by: @user, created_at: @now, updated_at: @now)
    resource.define_singleton_method(:representative_user) { representative }
    resource.define_singleton_method(:created_via_representation?) { true }
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-representation-label", text: /on behalf of/
    assert_selector "a[href='/u/alice']", text: "Alice Smith"
  end

  test "shows AI agent label when author is AI agent with parent" do
    owner = build_user(display_name: "Owner", handle: "owner")
    agent = build_user(display_name: "Bot", handle: "bot", user_type: "ai_agent", parent: owner)
    resource = build_note(created_by: agent, created_at: @now, updated_at: @now)
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-ai-agent-label", text: /managed by/
    assert_selector "a[href='/u/owner']", text: "Owner"
  end

  test "shows updated info when updated more than 1 minute after creation" do
    resource = build_note(created_by: @user, created_at: 1.hour.ago, updated_at: Time.current)
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-feed-item-updated", text: /Updated/
  end

  test "does not show updated info when updated within 1 minute" do
    resource = build_note(created_by: @user, created_at: @now, updated_at: @now + 30.seconds)
    render_inline(AuthorComponent.new(resource: resource))
    assert_no_selector ".pulse-feed-item-updated"
  end

  test "shows updater name when different from author" do
    updater = build_user(display_name: "Charlie", handle: "charlie")
    resource = build_note(created_by: @user, created_at: 1.hour.ago, updated_at: Time.current)
    resource.define_singleton_method(:updated_by) { updater }
    render_inline(AuthorComponent.new(resource: resource))
    assert_selector ".pulse-feed-item-updated a[href='/u/charlie']", text: "Charlie"
  end
end
