# typed: false

require "test_helper"

class CountdownComponentTest < ViewComponent::TestCase
  test "renders time element with countdown controller" do
    render_inline(CountdownComponent.new(datetime: 1.day.from_now))

    assert_selector "time[data-controller='countdown']"
  end

  test "renders end-time value as ISO 8601" do
    target_time = 2.days.from_now
    render_inline(CountdownComponent.new(datetime: target_time))

    assert_selector "time[data-countdown-end-time-value='#{target_time.iso8601}']"
  end

  test "renders base-unit value defaulting to seconds" do
    render_inline(CountdownComponent.new(datetime: 1.hour.from_now))

    assert_selector "time[data-countdown-base-unit-value='seconds']"
  end

  test "renders custom base-unit" do
    render_inline(CountdownComponent.new(datetime: 1.hour.from_now, base_unit: "minutes"))

    assert_selector "time[data-countdown-base-unit-value='minutes']"
  end

  test "renders time target span" do
    render_inline(CountdownComponent.new(datetime: 1.hour.from_now))

    assert_selector "span[data-countdown-target='time']"
  end
end
