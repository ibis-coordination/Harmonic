# typed: true

# The place switcher at every width: destinations (globe, chat,
# collectives, create/join) as labeled rows in a slide-over sheet, opened
# from the header's places toggle on desktop and the tab bar's Places tab
# on mobile. Opened/closed by the places-sheet Stimulus controller; badges
# stay fresh via a places-badges controller instance listening to the
# shared unread-count broadcast.
class PlacesSheetComponent < ViewComponent::Base
  extend T::Sig
  include UnreadBadgeDisplay
  include PlaceActiveStates

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

  sig { params(collective: Collective).returns(Integer) }
  def unread_count_for(collective)
    @unread_counts[collective.id].to_i
  end
end
