require "test_helper"

class WebhooksUiTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @superagent = @global_superagent
    @superagent.enable_api!
    @user = @global_user
    # Make user an admin of the studio
    @superagent_member = SuperagentMember.find_by(superagent: @superagent, user: @user)
    @superagent_member.add_role!('admin')

    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @plaintext_token = @api_token.plaintext_token
    @headers = {
      "Authorization" => "Bearer #{@plaintext_token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def is_markdown?
    response.content_type.starts_with?("text/markdown")
  end

  test "GET webhooks index returns markdown" do
    get "/studios/#{@superagent.handle}/settings/webhooks", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_match(/# Webhooks/, response.body)
  end

  test "GET new webhook returns markdown" do
    get "/studios/#{@superagent.handle}/settings/webhooks/new", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_match(/# New Webhook/, response.body)
  end

  test "POST create_webhook creates a webhook" do
    post "/studios/#{@superagent.handle}/settings/webhooks/new/actions/create_webhook",
      params: { name: "Test Webhook", url: "https://example.com/webhook", events: "*" }.to_json,
      headers: @headers

    assert_response :success
    assert is_markdown?
    assert_match(/Webhook created successfully/, response.body)

    webhook = Webhook.find_by(name: "Test Webhook")
    assert_not_nil webhook
    assert_equal "https://example.com/webhook", webhook.url
    assert_equal ["*"], webhook.events
    assert webhook.enabled?
  end

  test "GET webhook show returns markdown" do
    webhook = Webhook.create!(
      tenant: @tenant,
      superagent: @superagent,
      name: "Show Test Webhook",
      url: "https://example.com/show",
      events: ["note.created"],
      created_by: @user,
    )

    get "/studios/#{@superagent.handle}/settings/webhooks/#{webhook.id}", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_match(/# Webhook: Show Test Webhook/, response.body)
  end

  test "POST update_webhook updates a webhook" do
    webhook = Webhook.create!(
      tenant: @tenant,
      superagent: @superagent,
      name: "Update Test Webhook",
      url: "https://example.com/update",
      events: ["*"],
      created_by: @user,
    )

    post "/studios/#{@superagent.handle}/settings/webhooks/#{webhook.id}/actions/update_webhook",
      params: { name: "Updated Webhook Name" }.to_json,
      headers: @headers

    assert_response :success
    assert is_markdown?
    assert_match(/Webhook updated successfully/, response.body)

    webhook.reload
    assert_equal "Updated Webhook Name", webhook.name
  end

  test "POST delete_webhook deletes a webhook" do
    webhook = Webhook.create!(
      tenant: @tenant,
      superagent: @superagent,
      name: "Delete Test Webhook",
      url: "https://example.com/delete",
      events: ["*"],
      created_by: @user,
    )
    webhook_id = webhook.id

    post "/studios/#{@superagent.handle}/settings/webhooks/#{webhook.id}/actions/delete_webhook",
      headers: @headers

    assert_response :success
    assert is_markdown?
    assert_match(/Webhook deleted successfully/, response.body)

    assert_nil Webhook.find_by(id: webhook_id)
  end

  test "POST test_webhook sends a test" do
    webhook = Webhook.create!(
      tenant: @tenant,
      superagent: @superagent,
      name: "Test Webhook Send",
      url: "https://example.com/test",
      events: ["*"],
      created_by: @user,
    )

    post "/studios/#{@superagent.handle}/settings/webhooks/#{webhook.id}/actions/test_webhook",
      headers: @headers

    assert_response :success
    assert is_markdown?
    assert_match(/Test webhook sent/, response.body)

    # Verify a test event was created
    test_event = Event.find_by(event_type: "webhook.test", subject: webhook)
    assert_not_nil test_event

    # Verify a delivery was created
    delivery = WebhookDelivery.find_by(webhook: webhook, event: test_event)
    assert_not_nil delivery
  end

  test "non-admin cannot access webhooks" do
    # Remove admin status
    @superagent_member.remove_role!('admin')

    get "/studios/#{@superagent.handle}/settings/webhooks", headers: @headers
    assert_response :forbidden
  end

  test "webhook allows HTTP URL in test environment" do
    # HTTP URLs are allowed in development/test for local development convenience
    # HTTPS is required only in production (tested in webhook_test.rb)
    post "/studios/#{@superagent.handle}/settings/webhooks/new/actions/create_webhook",
      params: { name: "HTTP Webhook", url: "http://example.com/webhook", events: "*" }.to_json,
      headers: @headers

    assert_response :success
    assert_match(/Webhook created successfully/, response.body)
  end
end
