require "test_helper"

class EventTypeRegistryTest < ActiveSupport::TestCase
  test "every Tracked model's event types are registered" do
    Rails.application.eager_load!
    prefixes = ApplicationRecord.descendants
      .select { |m| m.respond_to?(:is_tracked?) && m.is_tracked? }
      .map { |m| T.must(m.name).underscore }

    assert_includes prefixes, "note", "sanity: Tracked models should be discoverable"

    # Note emits under "comment" when the record is a comment.
    (prefixes + ["comment"]).each do |prefix|
      %w[created updated deleted].each do |verb|
        assert EventTypeRegistry.registered?("#{prefix}.#{verb}"),
          "#{prefix}.#{verb} is emitted by Tracked but not registered"
      end
    end
  end

  test "explicit collective-audience types are registered" do
    %w[
      decision.deadline_reached
      commitment.deadline_reached
      commitment.joined
      commitment.critical_mass
      invite.accepted
      collective_member.role_granted
    ].each do |event_type|
      assert_equal :collective, EventTypeRegistry.audience_for(event_type), event_type
    end
  end

  test "delivery types are single-recipient" do
    %w[notifications.delivered reminders.delivered].each do |event_type|
      assert_equal :single_recipient, EventTypeRegistry.audience_for(event_type), event_type
      assert EventTypeRegistry.single_recipient?(event_type)
    end
  end

  test "audience_for raises on an unregistered type" do
    assert_raises(EventTypeRegistry::UnknownEventType) do
      EventTypeRegistry.audience_for("made.up")
    end
  end

  test "single_recipient? tolerates unregistered types" do
    assert_not EventTypeRegistry.single_recipient?("made.up")
  end
end
