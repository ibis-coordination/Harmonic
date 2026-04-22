# typed: false

require "test_helper"
require_relative "component_test_helper"

class CommentComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  setup do
    @user = build_user(display_name: "Alice", handle: "alice")
    @comment = build_note(
      truncated_id: "abc12345",
      text: "Hello world",
      created_at: 1.hour.ago,
      created_by: @user
    )
    @comment.define_singleton_method(:commentable_type) { "Decision" }
    @comment.define_singleton_method(:commentable) { nil }
  end

  test "renders comment with author" do
    render_inline(CommentComponent.new(
                    comment: @comment,
                    show_reply_context: false,
                    root_comment_id: "root123"
                  ))
    assert_selector ".pulse-comment"
    assert_selector ".pulse-comment-author", text: "Alice"
  end

  test "renders comment id anchor" do
    render_inline(CommentComponent.new(
                    comment: @comment,
                    show_reply_context: false,
                    root_comment_id: "root123"
                  ))
    assert_selector "#n-abc12345"
  end

  test "renders comment body" do
    render_inline(CommentComponent.new(
                    comment: @comment,
                    show_reply_context: false,
                    root_comment_id: "root123"
                  ))
    assert_text "Hello world"
  end

  test "renders timestamp link" do
    render_inline(CommentComponent.new(
                    comment: @comment,
                    show_reply_context: false,
                    root_comment_id: "root123"
                  ))
    assert_selector "a.pulse-comment-timestamp[href='/n/abc12345']"
  end

  test "renders confirmed reads display when no current user" do
    render_inline(CommentComponent.new(
                    comment: @comment,
                    show_reply_context: false,
                    root_comment_id: "root123",
                    current_user: nil
                  ))
    assert_selector ".pulse-comment-confirm-display"
    assert_no_selector ".pulse-comment-confirm-btn"
  end

  test "renders confirm button when current user has not confirmed" do
    render_inline(CommentComponent.new(
                    comment: @comment,
                    show_reply_context: false,
                    root_comment_id: "root123",
                    current_user: @user
                  ))
    assert_selector "button.pulse-comment-confirm-btn"
  end

  test "renders reply button when show_reply_button and current_user" do
    render_inline(CommentComponent.new(
                    comment: @comment,
                    show_reply_context: false,
                    root_comment_id: "root123",
                    show_reply_button: true,
                    current_user: @user
                  ))
    assert_selector ".pulse-comment-reply-btn", text: "Reply"
  end

  test "hides reply button when show_reply_button is false" do
    render_inline(CommentComponent.new(
                    comment: @comment,
                    show_reply_context: false,
                    root_comment_id: "root123",
                    show_reply_button: false,
                    current_user: @user
                  ))
    assert_no_selector ".pulse-comment-reply-btn"
  end

  test "hides reply button when no current user" do
    render_inline(CommentComponent.new(
                    comment: @comment,
                    show_reply_context: false,
                    root_comment_id: "root123",
                    show_reply_button: true,
                    current_user: nil
                  ))
    assert_no_selector ".pulse-comment-reply-btn"
  end

  test "renders representation label" do
    representative = build_user(display_name: "Bob", handle: "bob")
    comment = build_note(
      truncated_id: "rep12345",
      text: "On behalf comment",
      created_at: 1.hour.ago,
      created_by: @user
    )
    comment.define_singleton_method(:commentable_type) { "Decision" }
    comment.define_singleton_method(:commentable) { nil }
    comment.define_singleton_method(:representative_user) { representative }
    comment.define_singleton_method(:created_via_representation?) { true }

    render_inline(CommentComponent.new(
                    comment: comment,
                    show_reply_context: false,
                    root_comment_id: "root123"
                  ))
    assert_selector ".pulse-comment-author", text: "Bob"
    assert_selector ".pulse-representation-label", text: /on behalf of/
  end

  test "renders AI agent label" do
    parent = build_user(display_name: "Owner", handle: "owner")
    agent = build_user(display_name: "Bot", handle: "bot", user_type: "ai_agent", parent: parent)
    comment = build_note(
      truncated_id: "ai12345",
      text: "AI comment",
      created_at: 1.hour.ago,
      created_by: agent
    )
    comment.define_singleton_method(:commentable_type) { "Decision" }
    comment.define_singleton_method(:commentable) { nil }

    render_inline(CommentComponent.new(
                    comment: comment,
                    show_reply_context: false,
                    root_comment_id: "root123"
                  ))
    assert_selector ".pulse-ai-agent-label", text: /managed by/
  end

  test "renders reply context when applicable" do
    parent_author = build_user(display_name: "Dan", handle: "dan")
    parent_comment = build_note(truncated_id: "parent1", text: "Original comment text here", created_by: parent_author)
    reply = build_note(
      truncated_id: "reply123",
      text: "Reply text",
      created_at: 1.hour.ago,
      created_by: @user
    )
    reply.define_singleton_method(:commentable_type) { "Note" }
    reply.define_singleton_method(:commentable) { parent_comment }

    render_inline(CommentComponent.new(
                    comment: reply,
                    show_reply_context: true,
                    root_comment_id: "root123"
                  ))
    assert_selector ".pulse-comment-reply-context"
    assert_text "Replying to"
    assert_text "@dan"
  end

  test "does not render reply context when show_reply_context is false" do
    parent_author = build_user(display_name: "Dan", handle: "dan")
    parent_comment = build_note(truncated_id: "parent1", text: "Original", created_by: parent_author)
    reply = build_note(
      truncated_id: "reply123",
      text: "Reply text",
      created_at: 1.hour.ago,
      created_by: @user
    )
    reply.define_singleton_method(:commentable_type) { "Note" }
    reply.define_singleton_method(:commentable) { parent_comment }

    render_inline(CommentComponent.new(
                    comment: reply,
                    show_reply_context: false,
                    root_comment_id: "root123"
                  ))
    assert_no_selector ".pulse-comment-reply-context"
  end

  # --- Blocking ---

  test "renders collapsed placeholder when author is blocked" do
    author = build_user(display_name: "Blocked Author", handle: "blocked")
    comment = build_note(text: "Hidden comment", created_by: author)

    render_inline(CommentComponent.new(
      comment: comment,
      show_reply_context: false,
      root_comment_id: "root123",
      current_user: build_user(display_name: "Viewer", handle: "viewer"),
      blocked_user_ids: Set.new([author.id]),
    ))

    assert_selector ".pulse-comment-blocked-placeholder"
    assert_text "This comment is from a user you have blocked"
    assert_no_text "Hidden comment"
  end

  test "renders normally when author is not blocked" do
    author = build_user(display_name: "Normal Author", handle: "normal")
    comment = build_note(text: "Visible comment", created_by: author)

    render_inline(CommentComponent.new(
      comment: comment,
      show_reply_context: false,
      root_comment_id: "root123",
      current_user: build_user(display_name: "Viewer", handle: "viewer"),
      blocked_user_ids: Set.new,
    ))

    assert_no_selector ".pulse-comment-blocked-placeholder"
    assert_text "Visible comment"
  end
end
