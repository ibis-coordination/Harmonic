# typed: false

# Custom monochrome icons that aren't part of the upstream Octicons set.
#
# Each icon is a single SVG file under public/resource-icons/, used as a
# CSS mask so it inherits the surrounding text color — works on primary,
# secondary, and danger buttons without per-context variants. See
# `.pulse-icon` in pulse/_components.css.
#
# Usage:
#   <%= pulse_icon 'tuning_in' %>            # default: 20px
#   <%= pulse_icon 'tuning_in', size: :sm %> # 14px (matches octicon's small default)
#
# To add a new icon:
#   1. Drop the SVG at public/resource-icons/<name>-icon.svg (single color
#      via stroke="currentColor" / fill="currentColor" — color is irrelevant
#      under mask compositing but keep it explicit for direct viewing).
#   2. Add a `.pulse-icon-<name>` rule in pulse/_components.css pointing
#      mask-image at that file.
#   3. Add the kebab-cased name to AVAILABLE here.
module PulseIconHelper
  AVAILABLE = %w[tuning_in].freeze
  SIZE_CLASS = { default: nil, sm: "icon-sm" }.freeze

  def pulse_icon(name, size: :default)
    key = name.to_s.tr("-", "_")
    raise ArgumentError, "Unknown pulse_icon #{name.inspect}" unless AVAILABLE.include?(key)

    classes = ["pulse-icon", "pulse-icon-#{key.tr('_', '-')}", SIZE_CLASS.fetch(size)].compact
    tag.i(class: classes.join(" "), "aria-hidden": "true")
  end
end
