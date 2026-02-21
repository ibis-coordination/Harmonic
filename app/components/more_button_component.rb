# typed: true

class MoreButtonComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      resource: T.untyped,
      options: T::Array[String],
      studio: T.untyped,
      is_pinned: T::Boolean,
      main_collective: T.untyped,
    ).void
  end
  def initialize(resource:, options:, studio:, is_pinned: false, main_collective: nil) # rubocop:disable Metrics/ParameterLists
    super()
    @resource = resource
    @options = options
    @studio = studio
    @is_pinned = is_pinned
    @main_collective = main_collective
  end

  private

  sig { returns(String) }
  def pin_label
    location = @studio == @main_collective ? "your profile" : "studio homepage"
    "#{@is_pinned ? 'Unpin from' : 'Pin to'} #{location}"
  end

  sig { returns(String) }
  def pin_url
    "#{@resource.path}/pin"
  end
end
