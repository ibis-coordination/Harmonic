# typed: true

# Discord/Slack-style vertical rail for quick navigation between collectives
# (issue #337). The public space (the tenant's main collective) sits at the
# top as a bare globe icon — the only entry WITHOUT a square avatar. Below a
# divider, each collective the viewer belongs to is a square profile icon.
#
# Active states derive from the request path: the globe is active at the root
# path, a square on that collective's pages. current_collective cannot
# express this — it falls back to the main collective whenever the route has
# no collective handle (billing, settings, ...), which would light the globe
# up on every such page.
class CollectiveRailComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      main_collective: T.nilable(Collective),
      collectives: T::Array[Collective],
      current_path: T.nilable(String),
      unread_counts: T::Hash[String, Integer],
      chat_unread_count: Integer
    ).void
  end
  def initialize(main_collective: nil, collectives: [], current_path: nil, unread_counts: {}, chat_unread_count: 0)
    super()
    @main_collective = main_collective
    # Collective#path is nil for main collectives; an entry the rail cannot
    # link to is dropped rather than rendered with an empty href.
    @collectives = T.let(collectives.select { |c| c.path.present? }, T::Array[Collective])
    @current_path = current_path
    @unread_counts = unread_counts
    @chat_unread_count = chat_unread_count
  end

  sig { returns(T::Boolean) }
  def render?
    @main_collective.present? || @collectives.any?
  end

  private

  sig { params(collective: Collective).returns(T::Boolean) }
  def active?(collective)
    current = @current_path
    path = collective.path
    return false if current.nil? || path.nil?

    current == path || current.start_with?("#{path}/")
  end

  sig { returns(T::Boolean) }
  def public_space_active?
    @current_path == "/"
  end

  # The chat entry aggregates every chat collective behind one icon, so it
  # is active across all of /chat, and its count is type-based (unread
  # chat_message notifications), not collective-based.
  sig { returns(T::Boolean) }
  def chat_active?
    current = @current_path
    return false if current.nil?

    current == "/chat" || current.start_with?("/chat/")
  end

  # Server-rendered initial badge state, so navigation never flashes the
  # badges out. The rail-badges controller overwrites this on every poll
  # using the same display rules — keep the two in sync.
  sig { params(collective: Collective).returns(String) }
  def badge_text(collective)
    count_badge_text(@unread_counts[collective.id].to_i)
  end

  sig { params(collective: Collective).returns(T.nilable(String)) }
  def badge_style(collective)
    count_badge_style(@unread_counts[collective.id].to_i)
  end

  sig { returns(String) }
  def chat_badge_text
    count_badge_text(@chat_unread_count)
  end

  sig { returns(T.nilable(String)) }
  def chat_badge_style
    count_badge_style(@chat_unread_count)
  end

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
