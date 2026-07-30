# typed: true
# frozen_string_literal: true

# The closure status/restore screen — the only destination a closed account's
# session can reach during the grace window (see
# ApplicationController#check_account_closure).
class AccountClosuresController < ApplicationController
  def show
    user = current_user
    return redirect_to "/" unless user&.closing?

    @scrub_date = T.must(user.close_requested_at) + AccountClosureService::GRACE_PERIOD
  end

  def restore
    user = current_user
    return redirect_to "/" unless user&.closing?

    AccountClosureService.restore!(user: user)
    redirect_to "/", notice: "Your account has been restored."
  end
end
