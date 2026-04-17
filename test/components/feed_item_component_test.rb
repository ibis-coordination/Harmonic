# typed: false

require "test_helper"
require_relative "component_test_helper"

class FeedItemComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  DecisionResultStub = Struct.new(:option_title, :accepted_yes, :preferred, keyword_init: true)

  setup do
    # MarkdownRenderer needs tenant/collective context for link parsing
    Current.tenant_subdomain = "test"
    Current.collective_handle = "test-collective"
  end

  teardown do
    Current.reset
  end

  # --- Notes ---

  test "renders note with title and content" do
    note = build_note(title: "My Title", text: "Some content here")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_selector ".pulse-feed-item"
    assert_selector ".pulse-feed-item-title a", text: "My Title"
    assert_text "Some content here"
    assert_text "Alice"
  end

  test "renders comment type indicator for note comments" do
    commentable = build_note(truncated_id: "parent01", title: "Parent Note", text: "Parent text")
    note = build_note(text: "A reply", is_comment: true, commentable: commentable)
    user = build_user(display_name: "Bob")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 30.minutes.ago
                  ))
    assert_selector ".pulse-feed-item-type span", text: "Comment"
  end

  test "renders reply indicator with commentable link" do
    commentable = build_note(truncated_id: "parent01", title: "Parent Note", text: "Parent text")
    note = build_note(text: "A reply", is_comment: true, commentable: commentable)
    user = build_user(display_name: "Bob")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 30.minutes.ago
                  ))
    assert_selector ".pulse-feed-item-reply"
    assert_text "Replying to"
  end

  test "does not show separate title when note title matches text" do
    note = build_note(title: "Same content", text: "Same content")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_no_selector ".pulse-feed-item-title"
    assert_selector ".pulse-feed-item-content-clickable"
  end

  test "renders confirm read button when not read" do
    note = build_note(text: "Read me")
    user = build_user(display_name: "Alice")
    current_user = build_user(display_name: "Viewer", handle: "viewer")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago,
                    current_user: current_user
                  ))
    assert_selector "button", text: /Confirm read/
  end

  test "renders confirmed button when already read" do
    note = build_note(text: "Read me")
    note.define_singleton_method(:user_has_read?) { |_u| true }
    user = build_user(display_name: "Alice")
    current_user = build_user(display_name: "Viewer", handle: "viewer")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago,
                    current_user: current_user
                  ))
    assert_selector "button[disabled]", text: /Confirmed/
  end

  # --- Decisions ---

  test "renders decision with question as title" do
    decision = build_decision(question: "Should we proceed?")
    user = build_user(display_name: "Carol")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago
                  ))
    assert_selector ".pulse-feed-item-title a", text: "Should we proceed?"
    assert_selector ".pulse-feed-item-type span", text: "Decision"
  end

  test "shows decision options with vote counts" do
    results = [
      DecisionResultStub.new(option_title: "Option A", accepted_yes: 3, preferred: 2),
      DecisionResultStub.new(option_title: "Option B", accepted_yes: 1, preferred: 0),
    ]
    decision = build_decision(question: "Which way?", results: results)
    user = build_user(display_name: "Carol")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago
                  ))
    assert_selector ".pulse-decision-options"
    assert_text "Option A"
    assert_text "3 accept"
    assert_text "2 prefer"
  end

  test "highlights winner when decision closed" do
    results = [
      DecisionResultStub.new(option_title: "Winner", accepted_yes: 5, preferred: 3),
    ]
    decision = build_decision(question: "Who wins?", closed: true, results: results)
    user = build_user(display_name: "Carol")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago
                  ))
    assert_selector ".pulse-decision-option-winner"
    assert_selector ".pulse-feed-item-closed"
  end

  test "renders vote link when decision is open" do
    decision = build_decision(question: "Vote on this")
    user = build_user(display_name: "Carol")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago
                  ))
    assert_selector "a.pulse-feed-action-btn-link", text: /Vote/
  end

  test "renders closed button when decision is closed" do
    decision = build_decision(question: "Decided", closed: true)
    user = build_user(display_name: "Carol")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago
                  ))
    assert_selector "button[disabled]", text: /Closed/
  end

  # --- Commitments ---

  test "shows commitment progress bar" do
    commitment = build_commitment(title: "Let's do it", participant_count: 3, critical_mass: 5)
    user = build_user(display_name: "Dave")
    render_inline(FeedItemComponent.new(
                    item: commitment,
                    type: "Commitment",
                    created_by: user,
                    created_at: 3.hours.ago
                  ))
    assert_selector ".pulse-commitment-progress"
    assert_selector ".pulse-progress-fill[style='width: 60%']"
    assert_text "3 of 5 committed"
    assert_text "2 more needed"
  end

  test "shows critical mass reached when threshold met" do
    commitment = build_commitment(title: "Done!", participant_count: 5, critical_mass: 5)
    user = build_user(display_name: "Dave")
    render_inline(FeedItemComponent.new(
                    item: commitment,
                    type: "Commitment",
                    created_by: user,
                    created_at: 3.hours.ago
                  ))
    assert_text "Critical mass reached!"
  end

  test "renders join button when commitment open and not joined" do
    commitment = build_commitment(title: "Join us")
    user = build_user(display_name: "Dave")
    render_inline(FeedItemComponent.new(
                    item: commitment,
                    type: "Commitment",
                    created_by: user,
                    created_at: 3.hours.ago
                  ))
    assert_selector "button", text: /Join/
  end

  test "renders closed button when commitment is closed" do
    commitment = build_commitment(title: "Closed", closed: true)
    user = build_user(display_name: "Dave")
    render_inline(FeedItemComponent.new(
                    item: commitment,
                    type: "Commitment",
                    created_by: user,
                    created_at: 3.hours.ago
                  ))
    assert_selector "button[disabled]", text: /Closed/
  end

  # --- Representation ---

  test "renders representation label" do
    note = build_note(text: "On behalf content")
    representative = build_user(display_name: "Rep User", handle: "repuser")
    created_by = build_user(display_name: "Original Author", handle: "author")
    note.define_singleton_method(:created_via_representation?) { true }
    note.define_singleton_method(:representative_user) { representative }
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: created_by,
                    created_at: 1.hour.ago
                  ))
    assert_text "Rep User"
    assert_text "on behalf of"
    assert_text "Original Author"
  end

  # --- Anonymous ---

  test "renders anonymous when no author" do
    note = build_note(text: "Anonymous content")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: nil,
                    created_at: 1.hour.ago
                  ))
    assert_text "Anonymous"
  end
end
