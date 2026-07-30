# typed: true
# frozen_string_literal: true

# The deletion status/restore screen — the only destination a
# pending-deletion account's session can reach during the grace period (see
# ApplicationController#check_account_deletion).
class AccountDeletionsController < ApplicationController
  def show
    user = current_user
    return redirect_to "/" unless user&.pending_deletion?

    @scrub_date = T.must(user.deletion_requested_at) + AccountDeletionService::GRACE_PERIOD
  end

  def restore
    user = current_user
    return redirect_to "/" unless user&.pending_deletion?

    AccountDeletionService.restore!(user: user)
    redirect_to "/", notice: "Your account has been restored."
  end
end
