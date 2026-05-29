# typed: false

# Controller helpers for blocking actions that would move a collective from
# the free to the paid tier when the owner doesn't have Stripe billing set up.
#
# Usage in a form-style controller action:
#
#   if paid_transition_blocked?(@current_collective, trio_after: new_trio)
#     flash[:error] = paid_transition_error_message
#     return redirect_to "#{@current_collective.path}/settings"
#   end
#
# Or in an action_* endpoint:
#
#   if paid_transition_blocked?(@current_collective, has_enabled_automation_after: ...)
#     return render_action_error(... error: paid_transition_action_error)
#   end
#
# Each call site renders its own failure response (settings re-render with flash,
# action_error, etc.) — see the entry points wired in CollectiveAutomationsController,
# CollectivesController, and UsersController#update_workspace_trio.
module PaidTransitionGate
  extend ActiveSupport::Concern

  # Returns true when this action would move `collective` into paid_tier? AND
  # the owner has no billing set up. Caller is expected to halt and render an
  # appropriate failure response.
  def paid_transition_blocked?(collective, **overrides)
    return false unless collective.would_be_paid_tier?(**overrides)
    return false if collective.paid_tier?            # already paid, no transition
    return false if collective.owner_billing_setup?  # owner is covered

    true
  end

  # Flash message for form-style endpoints (settings forms) that redirect back
  # to the originating page.
  def paid_transition_error_message
    "Collective owner must set up billing at /billing before you can enable this feature."
  end

  # Error message for action_* endpoints (no flash, rendered inline).
  def paid_transition_action_error
    "This action would move the collective to the paid plan ($3/mo). " \
      "The collective owner must set up billing first (visit /billing)."
  end
end
