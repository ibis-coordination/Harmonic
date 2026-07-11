# typed: false

require "test_helper"

class MoneyParamTest < ActiveSupport::TestCase
  test "parses dollars into cents" do
    assert_equal 550, MoneyParam.dollars_to_cents("5.50")
    assert_equal 1, MoneyParam.dollars_to_cents("0.01")
  end

  test "blank clears" do
    assert_nil MoneyParam.dollars_to_cents("")
    assert_nil MoneyParam.dollars_to_cents("   ")
    assert_nil MoneyParam.dollars_to_cents(nil)
  end

  test "rejects non-numeric input" do
    assert_raises(ArgumentError) { MoneyParam.dollars_to_cents("lots") }
    assert_raises(ArgumentError) { MoneyParam.dollars_to_cents("$5") }
  end

  test "rejects amounts the cents column cannot store" do
    # 30,000,000 dollars = 3,000,000,000 cents > int4 max: without this
    # guard the write raises ActiveModel::RangeError at save time, past any
    # ArgumentError rescue.
    assert_raises(ArgumentError) { MoneyParam.dollars_to_cents("30000000") }
  end
end
