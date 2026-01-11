require "test_helper"

class WebhookTest < ActiveSupport::TestCase
  setup do
    @tenant, @studio, @user = create_tenant_studio_user
  end

  test "valid webhook creation" do
    webhook = Webhook.new(
      tenant: @tenant,
      studio: @studio,
      name: "Test Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )
    assert webhook.valid?
  end

  test "generates secret on create" do
    webhook = Webhook.create!(
      tenant: @tenant,
      studio: @studio,
      name: "Test Webhook",
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )
    assert_not_nil webhook.secret
    assert_equal 64, webhook.secret.length # 32 bytes = 64 hex chars
  end

  test "requires name" do
    webhook = Webhook.new(
      tenant: @tenant,
      studio: @studio,
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )
    assert_not webhook.valid?
    assert_includes webhook.errors[:name], "can't be blank"
  end

  test "requires https url" do
    webhook = Webhook.new(
      tenant: @tenant,
      studio: @studio,
      name: "Test Webhook",
      url: "http://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )
    assert_not webhook.valid?
    assert_includes webhook.errors[:url], "must use HTTPS"
  end

  test "requires events" do
    webhook = Webhook.new(
      tenant: @tenant,
      studio: @studio,
      name: "Test Webhook",
      url: "https://example.com/webhook",
      events: [],
      created_by: @user,
    )
    assert_not webhook.valid?
    assert_includes webhook.errors[:events], "can't be blank"
  end

  test "subscribed_to? returns true for matching event" do
    webhook = Webhook.new(
      events: ["note.created", "note.updated"],
    )
    assert webhook.subscribed_to?("note.created")
    assert webhook.subscribed_to?("note.updated")
    assert_not webhook.subscribed_to?("note.deleted")
  end

  test "subscribed_to? returns true for wildcard" do
    webhook = Webhook.new(events: ["*"])
    assert webhook.subscribed_to?("note.created")
    assert webhook.subscribed_to?("decision.voted")
    assert webhook.subscribed_to?("anything.here")
  end

  test "subscribed_to? returns false for empty events" do
    webhook = Webhook.new(events: [])
    assert_not webhook.subscribed_to?("note.created")
  end

  test "enabled scope returns only enabled webhooks" do
    Webhook.create!(
      tenant: @tenant,
      name: "Enabled Webhook",
      url: "https://example.com/webhook1",
      events: ["note.created"],
      created_by: @user,
      enabled: true,
    )
    Webhook.create!(
      tenant: @tenant,
      name: "Disabled Webhook",
      url: "https://example.com/webhook2",
      events: ["note.created"],
      created_by: @user,
      enabled: false,
    )

    enabled = Webhook.enabled
    assert_equal 1, enabled.count
    assert_equal "Enabled Webhook", enabled.first.name
  end
end
