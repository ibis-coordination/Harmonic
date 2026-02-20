# typed: false

class AccordionComponent < ViewComponent::Base
  # Renders a Pulse-styled accordion using <details>/<summary>.
  #
  # @param title [String] the accordion heading text
  # @param open [Boolean] whether the accordion starts expanded
  # @param count [Integer, String, nil] optional count displayed after the title
  # @param icon [String, nil] octicon name to display before the title
  # @param tooltip [String, nil] title attribute for the title area
  # @param title_data [Hash] data attributes to add to the title span
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

  def data_attributes
    @title_data.map { |k, v| "data-#{k}=\"#{v}\"" }.join(" ").html_safe
  end
end
