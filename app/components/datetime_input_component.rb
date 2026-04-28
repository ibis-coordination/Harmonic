# typed: true

class DatetimeInputComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      field_name: String,
      timezone_field_name: String,
      default_value: T.nilable(String),
      default_offset: String,
      require_future: T::Boolean,
      default_timezone: T.nilable(String),
    ).void
  end
  def initialize(
    field_name:,
    timezone_field_name: "timezone",
    default_value: nil,
    default_offset: "7d",
    require_future: true,
    default_timezone: nil
  )
    super()
    @field_name = field_name
    @timezone_field_name = timezone_field_name
    @default_value = default_value
    @default_offset = default_offset
    @require_future = require_future
    @default_timezone = default_timezone || "UTC"
  end
end
