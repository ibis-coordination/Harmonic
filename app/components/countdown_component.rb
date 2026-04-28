# typed: true

class CountdownComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      datetime: T.any(Time, ActiveSupport::TimeWithZone),
      base_unit: String,
    ).void
  end
  def initialize(datetime:, base_unit: "seconds")
    super()
    @datetime = datetime
    @base_unit = base_unit
  end
end
