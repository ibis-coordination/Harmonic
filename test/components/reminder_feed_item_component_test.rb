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

    render_inline(ReminderFeedItemComponent.new(note: note, happened_at: 30.minutes.ago.in_time_zone("UTC")))

    assert_selector ".pulse-feed-item"
    assert_selector "[data-item-type='Reminder']"
    assert_text "Reminder"
    assert_text "Review the PR"
    assert_selector "a[href='/n/rem12345']"
  end

  test "renders time ago" do
    note = build_note(title: "Check deploy")

    render_inline(ReminderFeedItemComponent.new(note: note, happened_at: 2.hours.ago.in_time_zone("UTC")))

    assert_text "2 hours ago"
  end
end
