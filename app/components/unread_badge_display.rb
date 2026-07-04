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

  # A badged place entry links to its feed filtered to what the viewer was
  # notified about; unbadged it links plainly (docs/NAVIGATION_DESIGN.md
  # "Badge click-through"). Applies to feed-backed places only — chat has
  # no feed, so its entry never swaps.
  sig { params(path: String, count: Integer).returns(String) }
  def place_entry_href(path, count)
    count.positive? ? "#{path}?q=my:notified" : path
  end
end
