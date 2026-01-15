require "test_helper"

class NotificationMailerTest < ActionMailer::TestCase
  test "notification_email sends email with correct content" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
      actor: user,
    )

    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Alice mentioned you",
      body: "Hey @test, check this out!",
      url: "/n/abc123",
    )

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "email",
      status: "pending",
    )

    email = NotificationMailer.notification_email(recipient)

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal [user.email], email.to
    assert_equal "Alice mentioned you", email.subject

    # Check both HTML and text parts contain the content
    body_content = email.body.encoded
    assert_match "Alice mentioned you", body_content
    assert_match "check this out", body_content
  end

  test "notification_email includes correct URL" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
      actor: user,
    )

    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "mention",
      title: "Test notification",
      url: "/n/abc123",
    )

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "email",
      status: "pending",
    )

    email = NotificationMailer.notification_email(recipient)

    # URL should include the path
    body_content = email.body.encoded
    assert_match "/n/abc123", body_content
  end

  test "notification_email handles notification without body" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
      actor: user,
    )

    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "system",
      title: "System notification",
      body: nil,
      url: "/notifications",
    )

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "email",
      status: "pending",
    )

    email = NotificationMailer.notification_email(recipient)

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal "System notification", email.subject
  end

  test "notification_email handles notification without URL" do
    tenant, superagent, user = create_tenant_superagent_user
    Superagent.scope_thread_to_superagent(subdomain: tenant.subdomain, handle: superagent.handle)

    event = Event.create!(
      tenant: tenant,
      superagent: superagent,
      event_type: "note.created",
      actor: user,
    )

    notification = Notification.create!(
      tenant: tenant,
      event: event,
      notification_type: "system",
      title: "System notification",
      url: nil,
    )

    recipient = NotificationRecipient.create!(
      notification: notification,
      user: user,
      channel: "email",
      status: "pending",
    )

    email = NotificationMailer.notification_email(recipient)

    assert_emails 1 do
      email.deliver_now
    end
  end
end
