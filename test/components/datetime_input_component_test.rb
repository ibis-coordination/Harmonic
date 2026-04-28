# typed: false

require "test_helper"

class DatetimeInputComponentTest < ViewComponent::TestCase
  test "renders datetime-local input with correct name" do
    render_inline(DatetimeInputComponent.new(field_name: "scheduled_for"))

    assert_selector "input[type='datetime-local'][name='scheduled_for']"
  end

  test "renders timezone select with correct name" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline"))

    assert_selector "select[name='timezone']"
  end

  test "renders custom timezone field name" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline", timezone_field_name: "tz"))

    assert_selector "select[name='tz']"
  end

  test "renders Stimulus controller data attributes" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline"))

    assert_selector "[data-controller='datetime-input']"
    assert_selector "[data-datetime-input-target='datetimeInput']"
    assert_selector "[data-datetime-input-target='timezoneSelect']"
    assert_selector "[data-datetime-input-target='error']", visible: :all
  end

  test "renders default offset value attribute" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline", default_offset: "2d"))

    assert_selector "[data-datetime-input-default-offset-value='2d']"
  end

  test "renders require future value attribute" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline", require_future: false))

    assert_selector "[data-datetime-input-require-future-value='false']"
  end

  test "renders pre-filled value when provided" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline", default_value: "2030-06-15T14:00"))

    assert_selector "input[type='datetime-local'][value='2030-06-15T14:00']"
  end

  test "renders error span hidden by default" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline"))

    assert_selector "[data-datetime-input-target='error'][style*='display: none']", visible: :all
  end

  test "renders change action on datetime input" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline"))

    assert_selector "input[data-action='change->datetime-input#validate']"
  end

  test "renders change action on timezone select" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline"))

    assert_selector "select[data-action='change->datetime-input#validate']"
  end

  test "renders countdown preview element" do
    render_inline(DatetimeInputComponent.new(field_name: "deadline"))

    assert_selector "[data-datetime-input-target='countdown']", visible: :all
    assert_selector "[data-controller='countdown']", visible: :all
  end
end
