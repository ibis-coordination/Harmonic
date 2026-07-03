# typed: true

# Shared "where am I" rules for the rail and the places sheet — both are
# projections of the same destinations, so a place must light up (or not)
# identically in each. Path-based, never current_collective-based: the
# current-collective fallback would activate the public space on every
# handle-less route (/billing, /settings, ...). Expects the including
# component to set @current_path.
module PlaceActiveStates
  extend T::Sig

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
  # is active across all of /chat.
  sig { returns(T::Boolean) }
  def chat_active?
    current = @current_path
    return false if current.nil?

    current == "/chat" || current.start_with?("/chat/")
  end
end
