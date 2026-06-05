# typed: true

# AjaxToggleButtonComponent wraps a <button> in the `ajax-toggle` Stimulus
# controller. On click it POSTs to the URL for the current state, then swaps
# the button's content to the other state's HTML — no page reload, no flash.
#
# The caller declares both states (`on` and `off`) and which one is currently
# active via `on:`. The component figures out which URL/HTML/class is
# "current" and which is "alt". If `on_class` / `off_class` are provided the
# button's className swaps on toggle too; otherwise `css_class` is used for
# both states.
#
#   <%= render AjaxToggleButtonComponent.new(
#         on:        @target_on_my_list,
#         on_url:    "/u/dan/actions/tune_out",
#         on_html:   pulse_icon('tuning_in', size: :sm) + ' Tuned in',
#         on_class:  "pulse-action-btn-secondary",
#         off_url:   "/u/dan/actions/tune_in",
#         off_html:  octicon('plus',  height: 14) + ' Tune in',
#         off_class: "pulse-action-btn",
#         title:     "Toggle this user on your list",
#       ) %>
class AjaxToggleButtonComponent < ViewComponent::Base
  extend T::Sig

  SafeString = T.type_alias { T.any(String, ActiveSupport::SafeBuffer) }

  sig do
    params(
      on: T::Boolean,
      on_url: String,
      on_html: SafeString,
      off_url: String,
      off_html: SafeString,
      css_class: String,
      on_class: T.nilable(String),
      off_class: T.nilable(String),
      title: T.nilable(String)
    ).void
  end
  def initialize(on:, on_url:, on_html:, off_url:, off_html:,
                 css_class: "pulse-action-btn-secondary",
                 on_class: nil, off_class: nil, title: nil)
    super()
    @on = on
    @on_url = on_url
    @on_html = on_html
    @off_url = off_url
    @off_html = off_html
    @on_class = on_class || css_class
    @off_class = off_class || css_class
    # If both states share the same class, leave `alt_class` empty so the
    # Stimulus controller knows it doesn't need to swap.
    @class_swaps = @on_class != @off_class
    @title = title
  end

  private

  sig { returns(String) }
  def current_url
    @on ? @on_url : @off_url
  end

  sig { returns(String) }
  def alt_url
    @on ? @off_url : @on_url
  end

  sig { returns(SafeString) }
  def current_html
    @on ? @on_html : @off_html
  end

  sig { returns(String) }
  def alt_html
    (@on ? @off_html : @on_html).to_s
  end

  sig { returns(String) }
  def current_class
    @on ? @on_class : @off_class
  end

  sig { returns(String) }
  def alt_class
    return "" unless @class_swaps
    @on ? @off_class : @on_class
  end
end
