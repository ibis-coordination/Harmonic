# typed: true

class BreadcrumbComponent < ViewComponent::Base
  extend T::Sig

  sig { params(items: T::Array[T.any(String, [String, String])]).void }
  def initialize(items:)
    super()
    @items = items
  end
end
