# typed: true

class ResourceHeaderComponent < ViewComponent::Base
  extend T::Sig

  renders_one :actions

  sig do
    params(
      type_label: String,
      title: T.nilable(String),
      icon_name: T.nilable(String),
      icon_class: T.nilable(String),
      status: T.nilable(String)
    ).void
  end
  def initialize(type_label:, title:, icon_name: nil, icon_class: nil, status: nil)
    super()
    @type_label = type_label
    @title = title
    @icon_name = icon_name
    @icon_class = icon_class
    @status = status
  end

  private

  sig { returns(String) }
  def status_label
    @status == "closed" ? "Closed" : "Open"
  end
end
