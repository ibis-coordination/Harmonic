# typed: false

require "test_helper"
require_relative "component_test_helper"

class CommentsListComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  setup do
    @user = build_user(display_name: "Alice", handle: "alice")
  end

  test "renders empty state when no comments" do
    commentable = build_note(text: "commentable")
    commentable.define_singleton_method(:comments_with_threads) { { top_level: [], threads: {} } }
    render_inline(CommentsListComponent.new(commentable: commentable))
    assert_selector ".pulse-comments-empty", text: "No comments yet."
  end

  test "renders comment-thread Stimulus controller" do
    commentable = build_note(text: "commentable")
    commentable.define_singleton_method(:comments_with_threads) { { top_level: [], threads: {} } }
    render_inline(CommentsListComponent.new(commentable: commentable))
    assert_selector "[data-controller='comment-thread']"
  end

  test "renders top-level comments" do
    comment = build_note(truncated_id: "abc12345", text: "Top level", created_by: @user, created_at: 1.hour.ago)
    comment.define_singleton_method(:id) { 1 }
    comment.define_singleton_method(:commentable_type) { "Decision" }
    comment.define_singleton_method(:commentable) { nil }
    comment.define_singleton_method(:commentable_id) { nil }

    commentable = build_note(text: "commentable")
    commentable.define_singleton_method(:comments_with_threads) { { top_level: [comment], threads: {} } }

    render_inline(CommentsListComponent.new(commentable: commentable))
    assert_selector ".pulse-comment", count: 1
    assert_text "Top level"
  end

  test "renders replies toggle when thread has descendants" do
    top_comment = build_note(truncated_id: "top12345", text: "Top comment", created_by: @user, created_at: 2.hours.ago)
    top_comment.define_singleton_method(:id) { 1 }
    top_comment.define_singleton_method(:commentable_type) { "Decision" }
    top_comment.define_singleton_method(:commentable) { nil }
    top_comment.define_singleton_method(:commentable_id) { nil }

    reply = build_note(truncated_id: "rep12345", text: "Reply comment", created_by: @user, created_at: 1.hour.ago)
    reply.define_singleton_method(:id) { 2 }
    reply.define_singleton_method(:commentable_type) { "Note" }
    reply.define_singleton_method(:commentable) { nil }
    reply.define_singleton_method(:commentable_id) { 1 }

    commentable = build_note(text: "commentable")
    commentable.define_singleton_method(:comments_with_threads) { { top_level: [top_comment], threads: { 1 => [reply] } } }

    render_inline(CommentsListComponent.new(commentable: commentable))
    assert_selector ".pulse-replies-toggle"
    assert_text "1 reply"
  end

  test "renders reply form when current_user present" do
    comment = build_note(truncated_id: "abc12345", text: "Comment", created_by: @user, created_at: 1.hour.ago)
    comment.define_singleton_method(:id) { 1 }
    comment.define_singleton_method(:commentable_type) { "Decision" }
    comment.define_singleton_method(:commentable) { nil }
    comment.define_singleton_method(:commentable_id) { nil }

    commentable = build_note(text: "commentable")
    commentable.define_singleton_method(:comments_with_threads) { { top_level: [comment], threads: {} } }

    render_inline(CommentsListComponent.new(
                    commentable: commentable,
                    current_user: @user,
                    studio_path: "/s/my-studio"
                  ))
    assert_selector ".pulse-reply-form-container", visible: :all
    assert_selector "textarea", visible: :all
  end

  test "does not render reply form when no current_user" do
    comment = build_note(truncated_id: "abc12345", text: "Comment", created_by: @user, created_at: 1.hour.ago)
    comment.define_singleton_method(:id) { 1 }
    comment.define_singleton_method(:commentable_type) { "Decision" }
    comment.define_singleton_method(:commentable) { nil }
    comment.define_singleton_method(:commentable_id) { nil }

    commentable = build_note(text: "commentable")
    commentable.define_singleton_method(:comments_with_threads) { { top_level: [comment], threads: {} } }

    render_inline(CommentsListComponent.new(commentable: commentable, current_user: nil))
    assert_no_selector ".pulse-reply-form-container", visible: :all
  end

  test "passes studio_path to mention autocomplete" do
    comment = build_note(truncated_id: "abc12345", text: "Comment", created_by: @user, created_at: 1.hour.ago)
    comment.define_singleton_method(:id) { 1 }
    comment.define_singleton_method(:commentable_type) { "Decision" }
    comment.define_singleton_method(:commentable) { nil }
    comment.define_singleton_method(:commentable_id) { nil }

    commentable = build_note(text: "commentable")
    commentable.define_singleton_method(:comments_with_threads) { { top_level: [comment], threads: {} } }

    render_inline(CommentsListComponent.new(
                    commentable: commentable,
                    current_user: @user,
                    studio_path: "/s/my-studio"
                  ))
    assert_selector "[data-mention-autocomplete-studio-path-value='/s/my-studio']", visible: :all
  end
end
