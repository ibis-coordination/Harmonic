# typed: true

class AccordionComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      title: String,
      open: T::Boolean,
      count: T.nilable(T.any(Integer, String)),
      icon: T.nilable(String),
      tooltip: T.nilable(String),
      title_data: T::Hash[String, String]
    ).void
  end
  def initialize(title:, open: false, count: nil, icon: nil, tooltip: nil, title_data: {}) # rubocop:disable Metrics/ParameterLists
    super()
    @title = title
    @open = open
    @count = count
    @icon = icon
    @tooltip = tooltip
    @title_data = title_data
  end

  private

  sig { returns(String) }
  def data_attributes
    @title_data.map { |k, v| "data-#{k}=\"#{v}\"" }.join(" ").html_safe
  end
end
