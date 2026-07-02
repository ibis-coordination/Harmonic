# typed: true

class NotificationService
  extend T::Sig

  sig do
    params(
      event: Event,
      recipient: User,
      notification_type: String,
      title: String,
      body: T.nilable(String),
      url: T.nilable(String),
      channels: T::Array[String]
    ).returns(Notification)
  end
  def self.create_and_deliver!(event:, recipient:, notification_type:, title:, body: nil, url: nil, channels: ["in_app"])
    notification = Notification.create!(
      event: event,
      tenant_id: T.unsafe(event).tenant_id,
      notification_type: notification_type,
      title: title,
      body: body,
      url: url
    )

    channels.each do |channel|
      notification_recipient = NotificationRecipient.create!(
        notification: notification,
        user: recipient,
        channel: channel,
        status: "pending"
      )

      # Enqueue delivery job
      NotificationDeliveryJob.perform_later(notification_recipient.id)
    end

    # Fire notifications.delivered event (for user-notification webhooks).
    # Once per notification, regardless of channels. Reminders skip — they
    # fire reminders.delivered from ReminderDeliveryJob.
    fire_notifications_delivered_event(notification: notification, recipient: recipient, channels: channels)

    notification
  end

  # Notification type for trustee-authorization lifecycle events.
  TRUSTEE_NOTIFICATION_TYPE = "trustee_authorization"

  # Notify the affected party of a trustee-authorization lifecycle event.
  #
  # Unlike most notifications, trustee authorizations are user-relative, not
  # collective-relative — they live under /u/:handle/settings and have no
  # collective. The Event/EventService path used to create most notifications
  # requires a collective_id (NOT NULL), so we create the in-app notification
  # directly here instead of routing through EventService.record! +
  # NotificationDispatcher — the same pattern chat-message notifications use.
  #
  # Like chat, we still fire a `notifications.delivered` event so that user
  # notification-webhook subscribers (e.g. bridge agents) receive these. That
  # event needs a collective home; we use the recipient's private workspace —
  # a per-user collective the recipient is always a member of — mirroring how
  # chat scopes its delivered event to the chat session's private collective.
  # See deliver_trustee_notification!.
  #
  # event is one of :offered, :accepted. The recipient, originating actor, and
  # message are derived from the event so call sites stay one-liners. Declined
  # and revoked transitions deliberately fire nothing — the acting party
  # already knows they declined/revoked, and the counterparty learns of it
  # next time they look rather than via an inbox ping.
  sig { params(grant: TrusteeGrant, event: Symbol).void }
  def self.notify_trustee_authorization_event!(grant:, event:)
    granting = grant.granting_user
    trustee = grant.trustee_user
    granting_name = granting&.display_name || granting&.name || "Someone"
    trustee_name = trustee&.display_name || trustee&.name || "Someone"

    case event
    when :offered
      recipient = trustee
      actor = granting
      title = "#{granting_name} invited you to act on their behalf as a trustee"
    when :accepted
      recipient = granting
      actor = trustee
      title = "#{trustee_name} accepted your trustee authorization"
    else
      raise ArgumentError, "Unknown trustee authorization event: #{event.inspect}"
    end

    return if recipient.nil?

    deliver_trustee_notification!(grant: grant, recipient: recipient, actor: actor, title: title)
  end

  # Create or update a chat message notification for the recipient.
  # One notification per sender — if an undismissed notification from
  # the same sender already exists, we update its timestamp instead
  # of creating a duplicate.
  sig { params(sender: User, recipient: User, tenant: Tenant, url: String).void }
  def self.notify_chat_message!(sender:, recipient:, tenant:, url:)
    return if sender.id == recipient.id

    # Find existing unread chat_message notification from this sender to this
    # recipient. Read or dismissed ones don't suppress — a new message after
    # the recipient has seen the old notification is new information.
    existing = NotificationRecipient
      .joins(:notification)
      .where(user: recipient, tenant: tenant, channel: "in_app")
      .where(dismissed_at: nil, read_at: nil)
      .where(notifications: { notification_type: "chat_message", url: url })
      .first

    notification = if existing
                     # In-app inbox dedups: keep the existing notification so the recipient
                     # sees one consolidated row, not a pile of unread chat pings. The join
                     # on :notification above guarantees `existing.notification` is non-nil.
                     T.must(existing.notification)
                   else
                     n = Notification.create!(
                       tenant: tenant,
                       notification_type: "chat_message",
                       title: "New message from #{sender.display_name}",
                       url: url
                     )

                     NotificationRecipient.create!(
                       notification: n,
                       user: recipient,
                       tenant: tenant,
                       channel: "in_app",
                       status: "delivered",
                       delivered_at: Time.current
                     )

                     n
                   end

    channels = ["in_app"]

    # Unlike the in-app inbox, web push is per-message: the lock-screen ping
    # is the point of the channel, so every message gets its own recipient
    # row (on the possibly-reused notification) while the inbox keeps its
    # one-row-per-sender dedup.
    tenant_user = TenantUser.tenant_scoped_only(tenant.id).find_by(user: recipient)
    if tenant_user&.notification_channels_for("chat_message")&.include?("web_push")
      push_recipient = NotificationRecipient.create!(
        notification: notification,
        user: recipient,
        tenant: tenant,
        channel: "web_push",
        status: "pending"
      )
      NotificationDeliveryJob.perform_later(push_recipient.id)
      channels << "web_push"
    end

    # Always fire the event — every chat message is independently meaningful
    # to notification-webhook subscribers (external agents, integrations).
    # In-app dedup is a UX concern; webhook delivery is a transport concern.
    #
    # Chat-message notifications have no triggering Event, so the renderer's
    # `notification.event.actor` path returns nil. Pass the sender id through
    # metadata so the webhook payload still resolves an `actor`.
    fire_notifications_delivered_event(
      notification: notification,
      recipient: recipient,
      channels: channels,
      extra_metadata: { "original_actor_id" => sender.id }
    )
  end

  # Dismiss chat notifications from a specific sender for a user.
  # Called when the user replies, so the notification auto-clears.
  sig { params(user: User, sender: User, tenant: Tenant).void }
  def self.dismiss_chat_notifications_from!(user:, sender:, tenant:)
    sender_handle = TenantUser.tenant_scoped_only(tenant.id).find_by(user: sender)&.handle
    return unless sender_handle

    chat_url = "/chat/#{sender_handle}"

    NotificationRecipient
      .joins(:notification)
      .where(user: user, tenant: tenant, channel: "in_app")
      .where(dismissed_at: nil)
      .where(notifications: { notification_type: "chat_message", url: chat_url })
      .update_all(dismiss_attributes)
  end

  sig { params(user: User, tenant: Tenant).returns(Integer) }
  def self.unread_count_for(user, tenant:)
    # Exclude scheduled future reminders - they're not "unread" until their scheduled time
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .in_app.unread.not_scheduled.count
  end

  sig { params(user: User, tenant: Tenant).void }
  def self.dismiss_all_for(user, tenant:)
    # Exclude scheduled future reminders - they shouldn't be dismissed before they trigger
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .in_app.undismissed.not_scheduled.update_all(dismiss_attributes)
  end

  sig { params(user: User, tenant: Tenant, collective_id: String).returns(Integer) }
  def self.dismiss_all_for_collective(user, tenant:, collective_id:)
    # Dismiss all notifications for a specific collective
    # We bypass the collective scope on Event by using tenant_scoped_only
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .where(notification_id: notification_ids_for_collective(tenant, collective_id))
      .in_app.undismissed.not_scheduled
      .update_all(dismiss_attributes)
  end

  sig { params(user: User, tenant: Tenant).returns(Integer) }
  def self.dismiss_all_reminders(user, tenant:)
    # Dismiss all notifications without an event (i.e., reminders that have become due)
    NotificationRecipient
      .joins(:notification)
      .where(user: user, tenant: tenant)
      .where(notifications: { event_id: nil })
      .in_app.undismissed.not_scheduled
      .update_all(dismiss_attributes)
  end

  sig { params(user: User, tenant: Tenant).returns(Integer) }
  def self.mark_all_read_for(user, tenant:)
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .in_app.unread.not_scheduled
      .update_all(read_at: Time.current)
  end

  sig { params(user: User, tenant: Tenant, collective_id: String).returns(Integer) }
  def self.mark_all_read_for_collective(user, tenant:, collective_id:)
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .where(notification_id: notification_ids_for_collective(tenant, collective_id))
      .in_app.unread.not_scheduled
      .update_all(read_at: Time.current)
  end

  # Mark a user's in-app notifications about a specific resource (the event
  # subject, e.g. a Note being confirmed-read) as read. Used so that confirming
  # read on a note also clears the notification that pointed the user there.
  sig { params(user: User, tenant: Tenant, subject: ApplicationRecord).returns(Integer) }
  def self.mark_read_for_subject(user, tenant:, subject:)
    NotificationRecipient
      .where(user: user, tenant: tenant)
      .where(notification_id: notification_ids_for_subject(tenant, subject))
      .in_app.unread.not_scheduled
      .update_all(read_at: Time.current)
  end

  sig { params(user: User, tenant: Tenant).returns(Integer) }
  def self.mark_all_read_reminders(user, tenant:)
    # Mark all notifications without an event (i.e., reminders that have become due)
    NotificationRecipient
      .joins(:notification)
      .where(user: user, tenant: tenant)
      .where(notifications: { event_id: nil })
      .in_app.unread.not_scheduled
      .update_all(read_at: Time.current)
  end

  # Dismissing implies reading: rows dismissed in bulk keep an existing
  # read_at and get one stamped otherwise. The COALESCE reference is
  # table-qualified because some callers join :notification.
  sig { returns(T::Array[T.untyped]) }
  def self.dismiss_attributes
    now = Time.current
    ["dismissed_at = ?, status = 'dismissed', read_at = COALESCE(notification_recipients.read_at, ?)", now, now]
  end

  sig { params(tenant: Tenant, collective_id: String).returns(T::Array[String]) }
  def self.notification_ids_for_collective(tenant, collective_id)
    event_ids = Event.tenant_scoped_only(tenant.id).where(collective_id: collective_id).pluck(:id)
    Notification.tenant_scoped_only(tenant.id).where(event_id: event_ids).pluck(:id)
  end

  sig { params(tenant: Tenant, subject: ApplicationRecord).returns(T::Array[String]) }
  def self.notification_ids_for_subject(tenant, subject)
    event_ids = Event.tenant_scoped_only(tenant.id).for_subject(subject).pluck(:id)
    Notification.tenant_scoped_only(tenant.id).where(event_id: event_ids).pluck(:id)
  end

  # Fires `notifications.delivered` for user-notification webhook routing.
  # Skipped for reminder notifications — `ReminderDeliveryJob` fires
  # `reminders.delivered` for those.
  #
  # tenant_id/collective_id default to the thread context (the common case for
  # collective-scoped notifications and chat). Callers whose notification has
  # no thread collective context — trustee authorizations — pass them
  # explicitly; EventService.record! drops the event if collective_id is nil.
  sig do
    params(
      notification: Notification,
      recipient: User,
      channels: T::Array[String],
      tenant_id: T.nilable(String),
      collective_id: T.nilable(String),
      extra_metadata: T::Hash[String, T.untyped]
    ).void
  end
  def self.fire_notifications_delivered_event(notification:, recipient:, channels:, tenant_id: nil, collective_id: nil, extra_metadata: {})
    return if notification.notification_type == "reminder"

    metadata = {
      "notification_type" => notification.notification_type,
      "title" => notification.title,
      "body" => notification.body,
      "url" => notification.url,
      "channels" => channels,
    }.merge(extra_metadata)

    EventService.record!(
      event_type: "notifications.delivered",
      actor: recipient,
      subject: notification,
      metadata: metadata,
      tenant_id: tenant_id,
      collective_id: collective_id
    )
  rescue StandardError => e
    Rails.logger.error("Failed to fire notifications.delivered event: #{e.message}")
  end

  # Creates the trustee-authorization notification + recipient rows directly
  # (no triggering Event, since trustee grants have no collective). Channels
  # honor the recipient's per-type preferences, falling back to in-app. A
  # delivery failure is logged rather than raised so it never breaks the
  # underlying offer/accept action, which has already persisted.
  #
  # After the in-app/email rows are created we fire `notifications.delivered`
  # so notification-webhook subscribers receive these too (see
  # fire_notifications_delivered_event). `actor` is the originating party (the
  # one who offered/accepted), surfaced to the webhook payload
  # via `original_actor_id` exactly as the chat-message path does.
  sig { params(grant: TrusteeGrant, recipient: User, actor: T.nilable(User), title: String).void }
  def self.deliver_trustee_notification!(grant:, recipient:, actor:, title:)
    tenant = grant.tenant
    return if tenant.nil?

    tenant_user = TenantUser.tenant_scoped_only(tenant.id).find_by(user: recipient)
    channels = tenant_user ? tenant_user.notification_channels_for(TRUSTEE_NOTIFICATION_TYPE) : ["in_app"]
    return if channels.empty?

    url = trustee_grant_path_for(grant: grant, user: recipient, tenant: tenant)

    notification = Notification.create!(
      tenant: tenant,
      notification_type: TRUSTEE_NOTIFICATION_TYPE,
      title: title,
      url: url
    )

    channels.each do |channel|
      notification_recipient = NotificationRecipient.create!(
        notification: notification,
        user: recipient,
        tenant: tenant,
        channel: channel,
        status: "pending"
      )
      NotificationDeliveryJob.perform_later(notification_recipient.id)
    end

    # Route the delivered event through the recipient's private workspace — the
    # user-relative collective they always belong to — so the webhook dispatcher
    # (which requires the recipient to be a member of the event's collective)
    # forwards it. Mirrors chat's use of the chat session's private collective.
    workspace = Collective.tenant_scoped_only(tenant.id)
      .find_by(created_by_id: recipient.id, collective_type: "private_workspace")

    fire_notifications_delivered_event(
      notification: notification,
      recipient: recipient,
      channels: channels,
      tenant_id: tenant.id,
      collective_id: workspace&.id,
      extra_metadata: actor ? { "original_actor_id" => actor.id } : {}
    )
  rescue StandardError => e
    Rails.logger.error("Failed to deliver trustee authorization notification: #{e.message}")
  end

  # Builds the recipient-relative show path for a grant. The trustee-grants
  # controller authorizes by the :handle in the URL, so the link must point at
  # the recipient's own handle (not always the granting user's) or they'd be
  # forbidden from opening their own notification.
  sig { params(grant: TrusteeGrant, user: User, tenant: Tenant).returns(T.nilable(String)) }
  def self.trustee_grant_path_for(grant:, user:, tenant:)
    handle = TenantUser.tenant_scoped_only(tenant.id).find_by(user: user)&.handle
    return nil unless handle

    "/u/#{handle}/settings/trustee-authorizations/#{grant.truncated_id}"
  end

  private_class_method :dismiss_attributes, :notification_ids_for_collective,
                       :deliver_trustee_notification!, :trustee_grant_path_for
end
