require "test_helper"

class WebhookTest < ActiveSupport::TestCase
  setup do
    @tenant, @superagent, @user = create_tenant_superagent_user
  end

  test "valid webhook creation" do
    webhook = Webhook.new(
      tenant: @tenant,
      superagent: @superagent,
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
      superagent: @superagent,
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
      superagent: @superagent,
      url: "https://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )
    assert_not webhook.valid?
    assert_includes webhook.errors[:name], "can't be blank"
  end

  test "requires https url in production" do
    # HTTPS is only required in production, not in development/test
    # Test the validation method directly by simulating production environment
    webhook = Webhook.new(
      tenant: @tenant,
      superagent: @superagent,
      name: "Test Webhook",
      url: "http://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    # In test/development, HTTP should be allowed
    assert webhook.valid?, "HTTP URLs should be allowed in test environment"

    # Directly test the validation logic for production behavior
    # The validation method checks Rails.env.development? || Rails.env.test?
    # Since we're in test, it returns early. We verify HTTPS URLs always work.
    webhook.url = "https://example.com/webhook"
    assert webhook.valid?, "HTTPS URLs should always be valid"
  end

  test "allows http url in development and test" do
    webhook = Webhook.new(
      tenant: @tenant,
      superagent: @superagent,
      name: "Test Webhook",
      url: "http://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )
    assert webhook.valid?, "HTTP URLs should be allowed in test environment"
  end

  test "url_must_use_https_in_production validation adds error for http" do
    # Directly test the validation method behavior
    webhook = Webhook.new(
      tenant: @tenant,
      superagent: @superagent,
      name: "Test Webhook",
      url: "http://example.com/webhook",
      events: ["note.created"],
      created_by: @user,
    )

    # The validation skips in test env, so we call it in a production-like context
    # by temporarily checking what the error would be
    original_env = Rails.env
    begin
      # Simulate production by defining a custom env check
      Rails.instance_variable_set(:@_env, ActiveSupport::EnvironmentInquirer.new("production"))
      webhook.errors.clear
      webhook.url_must_use_https_in_production
      assert_includes webhook.errors[:url], "must use HTTPS"
    ensure
      Rails.instance_variable_set(:@_env, original_env)
    end
  end

  test "requires events" do
    webhook = Webhook.new(
      tenant: @tenant,
      superagent: @superagent,
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
