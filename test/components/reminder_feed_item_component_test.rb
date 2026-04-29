# typed: false

require "test_helper"
require_relative "component_test_helper"

class ReminderFeedItemComponentTest < ViewComponent::TestCase
  include ComponentTestHelper

  setup do
    Current.tenant_subdomain = "test"
    Current.collective_handle = "test-collective"
  end

  teardown do
    Current.reset
  end

  test "renders reminder event with note title and link" do
    note = build_note(title: "Review the PR", truncated_id: "rem12345")
    event = build_reminder_event(note: note, happened_at: 30.minutes.ago)

    render_inline(ReminderFeedItemComponent.new(event: event))

    assert_selector ".pulse-feed-item"
    assert_selector "[data-item-type='Reminder']"
    assert_text "Reminder"
    assert_text "Review the PR"
    assert_selector "a[href='/n/rem12345']"
  end

  test "renders time ago" do
    note = build_note(title: "Check deploy")
    event = build_reminder_event(note: note, happened_at: 2.hours.ago)

    render_inline(ReminderFeedItemComponent.new(event: event))

    assert_text "2 hours ago"
  end

  private

  def build_reminder_event(note:, happened_at: 1.hour.ago)
    event = NoteHistoryEvent.new(
      event_type: "reminder",
      happened_at: happened_at,
    )
    event.define_singleton_method(:note) { note }
    event
  end
end
