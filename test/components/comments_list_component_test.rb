# typed: false

require "test_helper"
require_relative "component_test_helper"

class CommentsListComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  setup do
    # Comment bodies render as block markdown, which resolves resource links
    # and needs tenant/collective context (see MarkdownRenderer#display_refereces).
    Current.tenant_subdomain = "test"
    Current.collective_handle = "test-collective"
    @user = build_user(display_name: "Alice", handle: "alice")
  end

  teardown do
    Current.reset
  end

  # A commentable (Decision) whose flat comment list is `comments`.
  def build_commentable(comments)
    commentable = build_decision
    commentable.define_singleton_method(:all_comments_chronological) { comments }
    commentable
  end

  # A top-level comment on the commentable (parent is the root resource).
  def build_top_level(truncated_id:, text:, created_by: nil)
    comment = build_note(truncated_id: truncated_id, text: text, created_by: created_by || @user, created_at: 2.hours.ago)
    comment.define_singleton_method(:commentable_type) { "Decision" }
    comment.define_singleton_method(:commentable_id) { nil }
    comment.define_singleton_method(:commentable) { nil }
    comment
  end

  # A reply to another comment (parent is a Note).
  def build_reply(truncated_id:, text:, parent:)
    reply = build_note(truncated_id: truncated_id, text: text, created_by: @user, created_at: 1.hour.ago)
    reply.define_singleton_method(:commentable_type) { "Note" }
    reply.define_singleton_method(:commentable_id) { 999 }
    reply.define_singleton_method(:commentable) { parent }
    reply
  end

  test "renders empty state when no comments" do
    render_inline(CommentsListComponent.new(commentable: build_commentable([])))
    assert_selector ".pulse-comments-empty", text: "No comments yet."
  end

  test "renders comment-thread Stimulus controller" do
    render_inline(CommentsListComponent.new(commentable: build_commentable([])))
    assert_selector "[data-controller='comment-thread']"
  end

  test "renders the displayed comment count (list size) as a data attribute for header resync" do
    top = build_top_level(truncated_id: "top12345", text: "Top")
    comments = [
      top,
      build_reply(truncated_id: "rep11111", text: "reply one", parent: top),
      build_reply(truncated_id: "rep22222", text: "reply two", parent: top),
    ]
    render_inline(CommentsListComponent.new(commentable: build_commentable(comments)))
    assert_selector ".pulse-comments-list[data-comment-count='3']"
  end

  test "renders every comment flat in one list" do
    top = build_top_level(truncated_id: "top12345", text: "Top level")
    reply = build_reply(truncated_id: "rep12345", text: "A reply", parent: top)

    render_inline(CommentsListComponent.new(commentable: build_commentable([top, reply])))
    assert_selector ".pulse-comment", count: 2
    assert_text "Top level"
    assert_text "A reply"
    # Flat list — no nested replies container or collapse toggle.
    assert_no_selector ".pulse-comment-replies"
    assert_no_selector ".pulse-replies-toggle"
  end

  test "shows reply context for replies but not for top-level comments" do
    top = build_top_level(truncated_id: "top12345", text: "Top level")
    parent_author = build_user(display_name: "Dan", handle: "dan")
    parent = build_note(truncated_id: "par12345", text: "Parent comment", created_by: parent_author)
    reply = build_reply(truncated_id: "rep12345", text: "A reply", parent: parent)

    render_inline(CommentsListComponent.new(commentable: build_commentable([top, reply])))
    assert_selector ".pulse-comment-reply-context", count: 1
    assert_text "Replying to"
    assert_text "@dan"
  end

  test "renders reply button that targets the composer when current_user present" do
    comment = build_top_level(truncated_id: "abc12345", text: "Comment")

    render_inline(CommentsListComponent.new(commentable: build_commentable([comment]), current_user: @user))
    assert_selector ".pulse-comment-reply-btn[data-action='click->comments#startReply']", text: "Reply"
    assert_selector ".pulse-comment-reply-btn[data-comment-path='/n/abc12345']"
  end

  test "does not render reply button when no current_user" do
    comment = build_top_level(truncated_id: "abc12345", text: "Comment")

    render_inline(CommentsListComponent.new(commentable: build_commentable([comment]), current_user: nil))
    assert_no_selector ".pulse-comment-reply-btn"
  end
end
