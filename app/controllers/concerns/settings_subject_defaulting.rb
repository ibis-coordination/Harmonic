# typed: false

# The canonical user-settings routes are handle-free (/settings/*, PR #420).
# Their subject is always the signed-in user — settings are self-only, since
# User#can_edit? is self-or-own-agent. The settings controllers still resolve
# their subject from params[:handle] (they were written for the old
# /u/:handle/settings routes, which the legacy redirect still feeds in). This
# concern fills params[:handle] with the current user's handle when it's absent,
# so those action bodies work unchanged on the new routes.
#
# It only provides the method; each controller declares its own before_action,
# placed ahead of that controller's subject-resolution before_action (set_user /
# set_target_user / set_settings_user) so the handle is populated first. It must
# be a regular before_action, NOT prepend_before_action: the method reads
# current_user, which needs the tenant that ApplicationController's own
# before_actions resolve — prepending would run it before the tenant exists.
# users_controller — which also serves other users' non-settings pages — scopes
# it to just its settings actions.
module SettingsSubjectDefaulting
  extend ActiveSupport::Concern

  private

  def default_settings_handle_to_current_user
    params[:handle] ||= current_user&.handle
  end
end
