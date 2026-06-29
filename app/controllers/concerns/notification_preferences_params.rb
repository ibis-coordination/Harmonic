# typed: false

# Shared parsing of notification-preference params for the user and AI-agent
# settings controllers. Produces a { type => { channel => bool } } hash suitable
# for TenantUser#update_notification_preferences!.
module NotificationPreferencesParams
  extend ActiveSupport::Concern

  private

  # complete: true  — HTML form submit. Every known type/channel is written;
  #   unchecked boxes (which browsers omit from the payload) are recorded as
  #   false. The result is a full matrix, so the saved state matches the form.
  # complete: false — markdown action / partial update. Only the type/channel
  #   keys actually present in params are written; everything else is left
  #   untouched by the model's merge.
  def notification_preferences_from_params(complete:)
    boolean = ActiveModel::Type::Boolean.new
    raw = params[:notifications]
    raw = {} unless raw.respond_to?(:key?)

    preferences = {}
    TenantUser::NOTIFICATION_TYPE_LABELS.each_key do |type|
      type_params = raw[type]
      type_params = {} unless type_params.respond_to?(:key?)

      TenantUser::NOTIFICATION_CHANNELS.each do |channel|
        present = type_params.key?(channel)
        next unless complete || present

        # An absent box (browsers omit unchecked checkboxes) is a definite
        # false, not nil — the column is typed T::Hash[String, T::Boolean].
        # Boolean.cast(nil) returns nil, so coerce the absent path explicitly.
        (preferences[type] ||= {})[channel] = present ? boolean.cast(type_params[channel]) : false
      end
    end
    preferences
  end
end
