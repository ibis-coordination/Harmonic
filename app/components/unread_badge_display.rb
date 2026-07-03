# typed: true

# Shared display rules for the unread count pills on the rail and the
# places sheet. The rail-badges Stimulus controller reimplements the same
# rules for post-poll updates — keep the two in sync.
module UnreadBadgeDisplay
  extend T::Sig

  sig { params(count: Integer).returns(String) }
  def count_badge_text(count)
    return "" if count.zero?

    count > 99 ? "99+" : count.to_s
  end

  sig { params(count: Integer).returns(T.nilable(String)) }
  def count_badge_style(count)
    "display: none" if count.zero?
  end
end
