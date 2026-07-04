# typed: false

require "test_helper"
require_relative "component_test_helper"

class FeedItemComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  DecisionResultStub = Struct.new(:option_title, :accepted_yes, :preferred, keyword_init: true)
  OptionStub = Struct.new(:title, :created_at)

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

  test "comment cards navigate to the thread with the comment marked, not the isolated comment page" do
    commentable = build_note(truncated_id: "parent01", title: "Parent Note", text: "Parent text")
    note = build_note(truncated_id: "comment05", text: "A reply", is_comment: true, commentable: commentable,
                      commentable_type: "Note", commentable_id: "11111111-1111-1111-1111-111111111111")
    user = build_user(display_name: "Bob")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 30.minutes.ago
                  ))
    assert_selector ".pulse-feed-item[data-card-navigate-url-value='/n/parent01?comment_id=comment05']"
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

  test "renders statement type indicator and parent link for statement notes" do
    parent = build_note(truncated_id: "parent01", title: "Parent Note", text: "Parent text")
    note = build_note(text: "Statement text", is_statement: true, statementable: parent)
    user = build_user(display_name: "Bob")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 30.minutes.ago
                  ))
    assert_selector ".pulse-feed-item-type span", text: "Statement"
    assert_selector ".pulse-feed-item-reply"
    assert_text "Statement on"
    assert_no_selector ".pulse-feed-item-title"
  end

  test "renders summary type indicator and parent link for summary notes" do
    parent = build_note(truncated_id: "parent01", title: "Parent Note", text: "Parent text")
    note = build_note(text: "Summary text", is_summary: true, summarizable: parent)
    user = build_user(display_name: "Bob")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 30.minutes.ago
                  ))
    assert_selector ".pulse-feed-item-type span", text: "Summary"
    assert_selector ".pulse-feed-item-reply"
    assert_text "Summary of"
    assert_no_selector ".pulse-feed-item-title"
  end

  test "summary feed item without a summarizable parent omits the parent link" do
    note = build_note(text: "Summary text", is_summary: true)
    user = build_user(display_name: "Bob")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 30.minutes.ago
                  ))
    assert_selector ".pulse-feed-item-type span", text: "Summary"
    assert_no_selector ".pulse-feed-item-reply"
  end

  test "statement feed item without a statementable parent omits the parent link" do
    note = build_note(text: "Statement text", is_statement: true)
    user = build_user(display_name: "Bob")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 30.minutes.ago
                  ))
    assert_selector ".pulse-feed-item-type span", text: "Statement"
    assert_no_selector ".pulse-feed-item-reply"
  end

  test "does not show title row when persisted_title is blank (single-line body)" do
    note = build_note(title: nil, text: "Single line of content")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_no_selector ".pulse-feed-item-title"
    assert_text "Single line of content"
  end

  # Note#title falls back to the first line of text when persisted title is blank
  # (note.rb:126-131), so an old string-equality `show_title?` check rendered both
  # the synthesized title row AND the full content row for titleless multi-line
  # notes — the first line of text appeared twice. Gate the title row on whether
  # the persisted title is actually present.
  test "titleless multi-line note does NOT render the title row (first line stays in content only)" do
    note = build_note(title: nil, text: "First line of text\n\nSecond paragraph follows.")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_no_selector ".pulse-feed-item-title"
    # "First line of text" must appear exactly once in the rendered card body
    body_text = page.find(".pulse-feed-item-body").text
    assert_equal 1, body_text.scan("First line of text").size,
                 "expected the first line to appear exactly once, got: #{body_text.inspect}"
  end

  # Bug 2: previously the card body ran markdown through `truncate`, which
  # escapes its input by default — `**bold**` was rendered as a string of
  # literal `&lt;strong&gt;` tags. The fix renders the full markdown HTML and
  # leaves visual truncation to CSS line-clamp + a "Show more" Stimulus
  # controller (`card-expand`).
  test "note body renders markdown as real HTML, not escaped tags" do
    note = build_note(title: nil, text: "**bold word** and _italic word_")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_selector ".pulse-feed-item-content strong", text: "bold word"
    assert_selector ".pulse-feed-item-content em", text: "italic word"
    refute_includes rendered_content, "&lt;strong&gt;"
    refute_includes rendered_content, "&lt;em&gt;"
  end

  test "note body is wrapped in a card-expand stimulus controller with a Show more button" do
    note = build_note(title: nil, text: "Some body text here.")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_selector ".pulse-feed-item-content[data-controller~='card-expand']"
    assert_selector ".pulse-feed-item-content [data-card-expand-target='body'].pulse-feed-item-content-clamped"
    # Button starts hidden; the Stimulus controller un-hides it in connect()
    # when the clamped body overflows. data-no-navigate prevents the
    # card-navigate controller (bug 4) from also firing on the button click.
    # visible: :all because Capybara hides [hidden] elements by default.
    assert_selector ".pulse-feed-item-content button[data-card-expand-target='toggle'][data-no-navigate][hidden][aria-expanded='false']",
                    text: "Show more", visible: :all
  end

  test "article has role=link, tabindex=0, aria-label for keyboard navigation parity" do
    note = build_note(title: "Important update", text: "details")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_selector "article.pulse-feed-item[role='link'][tabindex='0']"
    # aria-label contains the item title so screen readers get context.
    assert_selector "article.pulse-feed-item[aria-label*='Important update']"
    assert_selector "article.pulse-feed-item[data-action*='keydown->card-navigate#keydown']"
  end

  # Bug 4: clicking anywhere on the card body should navigate to the item
  # show page (replaces the old inline onclick that only fired for titleless
  # notes). A Stimulus controller on the <article> handles it, with
  # data-no-navigate / interactive children short-circuiting.
  test "card article wires the card-navigate controller to the item path" do
    note = build_note(title: "T", text: "body")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_selector "article.pulse-feed-item[data-controller~='card-navigate']"
    assert_selector "article.pulse-feed-item[data-card-navigate-url-value='#{note.path}']"
  end

  test "decision card also wires card-navigate" do
    decision = build_decision(question: "Q?")
    user = build_user(display_name: "Carol")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_selector "article[data-controller~='card-navigate'][data-card-navigate-url-value='#{decision.path}']"
  end

  test "note WITH a persisted title still renders the title row above the content" do
    note = build_note(title: "Real title", text: "Body content separate from the title")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago
                  ))
    assert_selector ".pulse-feed-item-title a", text: "Real title"
    assert_text "Body content separate from the title"
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

  # Vote tallies are a blind-taste-test data leak when shown to users who haven't
  # voted yet — same rule the show page enforces via @show_results = closed? ||
  # current_user_has_voted (decisions_controller.rb:109). The feed card must
  # match.

  test "open decision: anon viewer sees option titles but NOT vote counts" do
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
                    created_at: 2.hours.ago,
                    current_user: nil,
                  ))
    assert_selector ".pulse-decision-options"
    assert_text "Option A"
    assert_no_selector ".pulse-option-votes"
    assert_no_text "accept"
    assert_no_text "prefer"
  end

  test "open decision: logged-in user who hasn't voted sees option titles but NOT counts" do
    results = [
      DecisionResultStub.new(option_title: "Option A", accepted_yes: 3, preferred: 2),
    ]
    decision = build_decision(question: "Which way?", results: results)
    decision.define_singleton_method(:user_has_voted?) { |_u| false }
    user = build_user(display_name: "Carol")
    viewer = build_user(display_name: "Viewer", handle: "viewer")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago,
                    current_user: viewer,
                  ))
    assert_text "Option A"
    assert_no_selector ".pulse-option-votes"
  end

  # Blind-taste-test data leak: the `decision_results` view orders by
  # accepted_yes DESC, preferred DESC, so even with counts hidden, an
  # unvoted viewer could infer the ranking just from the option order.
  # The unvoted branch must source from `options.order(:created_at)` (the
  # neutral show-page order), NOT from `results`.
  test "open decision: unvoted viewer sees options in creation order, NOT results-ranked order" do
    # The decision returns `options` (not `results`) for the unvoted branch;
    # we stub `options` to return an Array-like relation of OptionStubs.
    creation_ordered = [
      OptionStub.new("Apple", 3.days.ago),
      OptionStub.new("Banana", 2.days.ago),
      OptionStub.new("Cherry", 1.day.ago),
    ]
    decision = build_decision(question: "Which fruit?")
    decision.define_singleton_method(:user_has_voted?) { |_u| false }
    options_relation = Object.new
    options_relation.define_singleton_method(:order) { |*_| creation_ordered }
    decision.define_singleton_method(:options) { options_relation }

    user = build_user(display_name: "Carol")
    viewer = build_user(display_name: "Viewer", handle: "viewer")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago,
                    current_user: viewer,
                  ))
    titles = page.all(".pulse-decision-option span").map(&:text)
    assert_equal ["Apple", "Banana", "Cherry"], titles,
                 "expected options in creation order (neutral); got #{titles.inspect} — likely sourced from results (ranked)"
  end

  test "open decision: viewer who has voted sees counts" do
    results = [
      DecisionResultStub.new(option_title: "Option A", accepted_yes: 3, preferred: 2),
    ]
    decision = build_decision(question: "Which way?", results: results)
    decision.define_singleton_method(:user_has_voted?) { |_u| true }
    user = build_user(display_name: "Carol")
    viewer = build_user(display_name: "Viewer", handle: "viewer")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago,
                    current_user: viewer,
                  ))
    assert_selector ".pulse-option-votes"
    assert_text "3 accept"
    assert_text "2 prefer"
  end

  test "voted_decision_ids set short-circuits the per-card user_has_voted? query (N+1 fix)" do
    results = [
      DecisionResultStub.new(option_title: "Option A", accepted_yes: 3, preferred: 2),
    ]
    decision = build_decision(question: "Which way?", results: results)
    # Explicit ID — unpersisted Decisions have id=nil by default, which would
    # make `Set[nil].include?(nil)` true and let the test pass coincidentally
    # even if the lookup were broken.
    decision.define_singleton_method(:id) { "00000000-0000-0000-0000-000000000001" }
    # Stub the model method to BLOW UP if anyone calls it — the precomputed
    # set must be used instead, eliminating the EXISTS query per card.
    decision.define_singleton_method(:user_has_voted?) { |_u| raise "must not call: feed_builder set should short-circuit" }
    user = build_user(display_name: "Carol")
    viewer = build_user(display_name: "Viewer", handle: "viewer")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago,
                    current_user: viewer,
                    voted_decision_ids: Set.new([decision.id]),
                  ))
    assert_selector ".pulse-option-votes"
  end

  test "closed decision: counts always shown regardless of vote status" do
    results = [
      DecisionResultStub.new(option_title: "Winner", accepted_yes: 5, preferred: 3),
    ]
    decision = build_decision(question: "Decided", closed: true, results: results)
    user = build_user(display_name: "Carol")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago,
                    current_user: nil,
                  ))
    assert_selector ".pulse-option-votes"
    assert_text "5 accept"
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

  test "renders vote link when decision is open and viewer has NOT voted" do
    decision = build_decision(question: "Vote on this")
    decision.define_singleton_method(:user_has_voted?) { |_u| false }
    user = build_user(display_name: "Carol")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago,
                    current_user: user,
                  ))
    assert_selector "a.pulse-feed-action-btn-link", text: /Vote/
    assert_no_selector "button[disabled]", text: /Voted/
  end

  # Mirrors the Note "Confirm read" → "Confirmed" pattern: once you've acted on
  # the card, the primary action button collapses to a disabled affirmative so
  # you can see your own status at a glance in the feed.
  test "renders disabled Voted button when viewer has already voted on an open decision" do
    decision = build_decision(question: "Vote on this")
    decision.define_singleton_method(:user_has_voted?) { |_u| true }
    user = build_user(display_name: "Carol")
    viewer = build_user(display_name: "Viewer", handle: "viewer")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago,
                    current_user: viewer,
                  ))
    assert_selector "button[disabled]", text: /Voted/
    # The Vote link must NOT also render — only one primary action per card.
    assert_no_selector "a.pulse-feed-action-btn-link", text: /\AVote\z/
  end

  test "Voted button uses the precomputed voted_decision_ids set (no per-card EXISTS query)" do
    decision = build_decision(question: "Vote on this")
    decision.define_singleton_method(:id) { "00000000-0000-0000-0000-000000000002" }
    decision.define_singleton_method(:user_has_voted?) { |_u| raise "must not call: set should short-circuit" }
    user = build_user(display_name: "Carol")
    viewer = build_user(display_name: "Viewer", handle: "viewer")
    render_inline(FeedItemComponent.new(
                    item: decision,
                    type: "Decision",
                    created_by: user,
                    created_at: 2.hours.ago,
                    current_user: viewer,
                    voted_decision_ids: Set.new([decision.id]),
                  ))
    assert_selector "button[disabled]", text: /Voted/
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
                    created_at: 3.hours.ago,
                    current_user: user,
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

  # --- Blocking ---

  test "renders nothing when block exists between current user and author" do
    note = build_note(text: "Blocked content")
    author = build_user(display_name: "Blocked Author", handle: "blocked")
    viewer = build_user(display_name: "Viewer", handle: "viewer")

    render_inline(FeedItemComponent.new(
      item: note,
      type: "Note",
      created_by: author,
      created_at: 1.hour.ago,
      current_user: viewer,
      block_related_user_ids: Set.new([author.id]),
    ))

    assert_no_selector ".pulse-feed-item"
    assert_no_text "Blocked content"
  end

  test "renders normally when no block exists" do
    note = build_note(text: "Normal content")
    author = build_user(display_name: "Author", handle: "author")
    viewer = build_user(display_name: "Viewer", handle: "viewer")

    render_inline(FeedItemComponent.new(
      item: note,
      type: "Note",
      created_by: author,
      created_at: 1.hour.ago,
      current_user: viewer,
      block_related_user_ids: Set.new,
    ))

    assert_selector ".pulse-feed-item"
    assert_text "Normal content"
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

  test "renders Table type label for table notes" do
    note = build_note(text: "| A |\n| --- |\n| val |", subtype: "table")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago,
                  ))
    assert_selector ".pulse-feed-item-type span", text: "Table"
  end

  test "renders Note type label for regular notes (not Table)" do
    note = build_note(text: "Regular note")
    user = build_user(display_name: "Alice")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago,
                  ))
    assert_selector ".pulse-feed-item-type span", text: "Note"
  end

  test "renders Reminder type label for reminder notes" do
    note = build_note(text: "Don't forget", subtype: "reminder")
    user = build_user(display_name: "Bob")
    render_inline(FeedItemComponent.new(
                    item: note,
                    type: "Note",
                    created_by: user,
                    created_at: 1.hour.ago,
                  ))
    assert_selector ".pulse-feed-item-type span", text: "Reminder"
  end
end
