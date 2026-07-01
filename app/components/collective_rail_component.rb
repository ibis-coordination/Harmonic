# typed: true

# Discord/Slack-style vertical rail for quick navigation between collectives.
#
# The public space (the tenant's main collective) sits at the top, rendered as
# a bare eye icon — it is the only entry WITHOUT a square avatar. Below a
# divider, each collective the viewer belongs to is a square profile icon.
#
# This is a first-pass UI sketch for issue #337; expect iteration.
class CollectiveRailComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      main_collective: T.nilable(Collective),
      collectives: T::Array[Collective],
      current_collective: T.nilable(Collective),
    ).void
  end
  def initialize(main_collective: nil, collectives: [], current_collective: nil)
    super()
    @main_collective = main_collective
    @collectives = collectives
    @current_collective = current_collective
  end

  private

  # A specific collective square is active when the viewer is currently in it.
  sig { params(collective: Collective).returns(T::Boolean) }
  def active?(collective)
    current = @current_collective
    return false if current.nil?

    collective.id == current.id
  end

  # The public-space eye is active when the viewer is on the main collective
  # or in a context with no collective at all (e.g. the personal home feed).
  sig { returns(T::Boolean) }
  def public_space_active?
    current = @current_collective
    return true if current.nil?

    current.is_main_collective?
  end
end
