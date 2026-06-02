# typed: true

# AjaxToggleButtonComponent wraps a <button> in the `ajax-toggle` Stimulus
# controller. On click it POSTs to the URL for the current state, then swaps
# the button's content to the other state's HTML — no page reload, no flash.
#
# The caller declares both states (`on` and `off`) and which one is currently
# active via `on:`. The component figures out which URL/HTML is "current" and
# which is "alt".
#
#   <%= render AjaxToggleButtonComponent.new(
#         on:       @target_on_my_list,
#         on_url:   "/u/dan/actions/tune_out",
#         on_html:  pulse_icon('tuning_in', size: :sm) + ' Tuning in',
#         off_url:  "/u/dan/actions/tune_in",
#         off_html: octicon('plus',  height: 14) + ' Tune in',
#         title:    "Toggle this user on your list",
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
      title: T.nilable(String)
    ).void
  end
  def initialize(on:, on_url:, on_html:, off_url:, off_html:,
                 css_class: "pulse-action-btn-secondary", title: nil)
    super()
    @on = on
    @on_url = on_url
    @on_html = on_html
    @off_url = off_url
    @off_html = off_html
    @css_class = css_class
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
end
