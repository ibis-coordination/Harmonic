# typed: true

class TabsComponent < ViewComponent::Base
  extend T::Sig

  class Tab < T::Struct
    const :key, String
    const :label, String
    const :href, String
    const :count, T.nilable(Integer)
  end

  sig do
    params(
      tabs: T::Array[Tab],
      active_key: String,
      css_class: T.nilable(String)
    ).void
  end
  def initialize(tabs:, active_key:, css_class: nil)
    super()
    @tabs = tabs
    @active_key = active_key
    @css_class = css_class
  end
end
