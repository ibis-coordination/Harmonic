require "test_helper"

# Tests for trustee-authorization lifecycle notifications.
# These notifications are user-relative (no collective), so they are created
# directly by NotificationService rather than routed through EventService.
class NotificationServiceTrusteeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def setup
    @tenant = create_tenant(subdomain: "trustee-notif-#{SecureRandom.hex(4)}")
    @granting_user = create_user(email: "granting_#{SecureRandom.hex(4)}@example.com", name: "Alice")
    @trustee_user = create_user(email: "trusted_#{SecureRandom.hex(4)}@example.com", name: "Bob")
    @granting_tu = @tenant.add_user!(@granting_user, handle: "alice")
    @trustee_tu = @tenant.add_user!(@trustee_user, handle: "bob")
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
  end

  def build_grant
    TrusteeGrant.create!(
      tenant: @tenant,
      granting_user: @granting_user,
      trustee_user: @trustee_user,
      permissions: {},
    )
  end

  # =========================================================================
  # SERVICE-LEVEL ROUTING
  # =========================================================================

  test "offered notifies the trustee user with their own handle path" do
    grant = build_grant

    assert_difference ["Notification.count", "NotificationRecipient.count"], 1 do
      NotificationService.notify_trustee_authorization_event!(grant: grant, event: :offered)
    end

    notification = Notification.order(:created_at).last
    assert_equal "trustee_authorization", notification.notification_type
    assert_equal "/u/bob/settings/trustee-authorizations/#{grant.truncated_id}", notification.url
    assert_includes notification.title, "act on their behalf"

    recipient = notification.notification_recipients.first
    assert_equal @trustee_user, recipient.user
    assert_equal "in_app", recipient.channel
  end

  test "accepted notifies the granting user with their own handle path" do
    grant = build_grant

    assert_difference "Notification.count", 1 do
      NotificationService.notify_trustee_authorization_event!(grant: grant, event: :accepted)
    end

    notification = Notification.order(:created_at).last
    assert_equal "/u/alice/settings/trustee-authorizations/#{grant.truncated_id}", notification.url
    assert_includes notification.title, "accepted your trustee authorization"
    assert_equal @granting_user, notification.notification_recipients.first.user
  end

  # Only :offered and :accepted are notifying events. Declined/revoked are
  # intentionally not handled — they raise like any other unknown event, and
  # the model transitions no longer call the service for them.
  test "declined and revoked are not notifying events" do
    grant = build_grant

    [:declined, :revoked].each do |event|
      assert_raises(ArgumentError) do
        NotificationService.notify_trustee_authorization_event!(grant: grant, event: event)
      end
    end
  end

  test "unknown event raises ArgumentError" do
    grant = build_grant
    assert_raises(ArgumentError) do
      NotificationService.notify_trustee_authorization_event!(grant: grant, event: :exploded)
    end
  end

  test "honors recipient channel preferences when email is opted into" do
    grant = build_grant
    # Opt the trustee into email; both channels should now fan out.
    @trustee_tu.set_notification_preference!("trustee_authorization", "email", true)

    assert_difference "NotificationRecipient.count", 2 do
      NotificationService.notify_trustee_authorization_event!(grant: grant, event: :offered)
    end

    notification = Notification.order(:created_at).last
    assert_equal ["email", "in_app"], notification.notification_recipients.map(&:channel).sort
  end

  test "no recipient row created when all channels disabled" do
    grant = build_grant
    @trustee_tu.set_notification_preference!("trustee_authorization", "in_app", false)

    assert_no_difference ["Notification.count", "NotificationRecipient.count"] do
      NotificationService.notify_trustee_authorization_event!(grant: grant, event: :offered)
    end
  end

  test "delivery failure is swallowed and does not raise" do
    grant = build_grant
    # Force a failure mid-delivery; the underlying action must not blow up.
    Notification.stub(:create!, ->(*_) { raise "boom" }) do
      assert_nothing_raised do
        NotificationService.notify_trustee_authorization_event!(grant: grant, event: :offered)
      end
    end
  end

  # =========================================================================
  # notifications.delivered EVENT (webhook routing)
  # =========================================================================

  def delivered_events
    Event.tenant_scoped_only(@tenant.id).where(event_type: "notifications.delivered")
  end

  test "offered fires notifications.delivered scoped to the trustee's private workspace" do
    grant = build_grant
    before = delivered_events.count

    NotificationService.notify_trustee_authorization_event!(grant: grant, event: :offered)

    assert_equal before + 1, delivered_events.count
    delivered = delivered_events.order(:created_at).last
    # The recipient is the event actor (existing pipeline semantic) and must be
    # a member of the event's collective for webhook dispatch to forward it.
    assert_equal @trustee_user.id, delivered.actor_id
    assert_equal @trustee_user.private_workspace.id, delivered.collective_id
    # The originating party (granting user) is surfaced for the webhook payload.
    assert_equal @granting_user.id, delivered.metadata["original_actor_id"]
    assert_equal "trustee_authorization", delivered.metadata["notification_type"]
  end

  test "accepted fires notifications.delivered to the granting user with the trustee as actor" do
    grant = build_grant
    before = delivered_events.count

    NotificationService.notify_trustee_authorization_event!(grant: grant, event: :accepted)

    assert_equal before + 1, delivered_events.count
    delivered = delivered_events.order(:created_at).last
    assert_equal @granting_user.id, delivered.actor_id
    assert_equal @granting_user.private_workspace.id, delivered.collective_id
    assert_equal @trustee_user.id, delivered.metadata["original_actor_id"]
  end

  test "no notifications.delivered event when all channels are disabled" do
    grant = build_grant
    @trustee_tu.set_notification_preference!("trustee_authorization", "in_app", false)
    before = delivered_events.count

    NotificationService.notify_trustee_authorization_event!(grant: grant, event: :offered)

    assert_equal before, delivered_events.count
  end

  # =========================================================================
  # CALL-SITE WIRING (model state transitions)
  # =========================================================================

  test "accept! sends a notification to the granting user" do
    grant = build_grant

    assert_difference "Notification.count", 1 do
      grant.accept!
    end

    assert_equal @granting_user, Notification.order(:created_at).last.notification_recipients.first.user
  end

  test "decline! fires no notification" do
    grant = build_grant

    assert_no_difference ["Notification.count", "NotificationRecipient.count"] do
      grant.decline!
    end
  end

  test "revoke! fires no notification" do
    grant = build_grant
    grant.accept! # accept! itself notifies; revoke! must add nothing on top.

    assert_no_difference ["Notification.count", "NotificationRecipient.count"] do
      grant.revoke!
    end
  end
end
