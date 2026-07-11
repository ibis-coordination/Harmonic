# typed: true
# frozen_string_literal: true

# Parses user-entered dollar amounts into integer cents. One home for the
# rule so the HTML settings forms and the action API can't drift.
class MoneyParam
  extend T::Sig

  # Largest value an int4 cents column can hold. Enforced here because a
  # too-large value passes numericality validation and only raises
  # ActiveModel::RangeError at save time — past any ArgumentError rescue.
  MAX_CENTS = 2_147_483_647

  # Blank clears (nil); otherwise dollars to cents. Raises ArgumentError for
  # non-numeric input or amounts the column can't store.
  sig { params(raw: T.untyped).returns(T.nilable(Integer)) }
  def self.dollars_to_cents(raw)
    str = raw.to_s.strip
    return nil if str.empty?

    cents = (BigDecimal(str) * 100).to_i
    raise ArgumentError, "amount out of range" if cents.abs > MAX_CENTS

    cents
  end
end
