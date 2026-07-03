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
      unread_counts: T::Hash[String, Integer]
    ).void
  end
  def initialize(main_collective: nil, collectives: [], current_path: nil, unread_counts: {})
    super()
    @main_collective = main_collective
    # Collective#path is nil for main collectives; an entry the rail cannot
    # link to is dropped rather than rendered with an empty href.
    @collectives = T.let(collectives.select { |c| c.path.present? }, T::Array[Collective])
    @current_path = current_path
    @unread_counts = unread_counts
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

  # Server-rendered initial badge state, so navigation never flashes the
  # badges out. The rail-badges controller overwrites this on every poll
  # using the same display rules — keep the two in sync.
  sig { params(collective: Collective).returns(String) }
  def badge_text(collective)
    count = @unread_counts[collective.id].to_i
    return "" if count.zero?

    count > 99 ? "99+" : count.to_s
  end

  sig { params(collective: Collective).returns(T.nilable(String)) }
  def badge_style(collective)
    "display: none" if @unread_counts[collective.id].to_i.zero?
  end
end
