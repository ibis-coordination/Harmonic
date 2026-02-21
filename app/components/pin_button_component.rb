# typed: true

class PinButtonComponent < ViewComponent::Base
  extend T::Sig

  sig { params(resource: T.untyped, is_pinned: T::Boolean).void }
  def initialize(resource:, is_pinned:)
    super()
    @resource = resource
    @is_pinned = is_pinned
  end

  private

  sig { returns(String) }
  def pin_url
    "#{@resource.path}/pin"
  end

  sig { returns(String) }
  def title
    @is_pinned ? "Click to unpin" : "Click to pin"
  end

  sig { returns(String) }
  def label
    @is_pinned ? "Unpin" : "Pin"
  end
end
