require "test_helper"

class WebhooksUiTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @studio = @global_studio
    @studio.enable_api!
    @user = @global_user
    # Make user an admin of the studio
    @studio_user = StudioUser.find_by(studio: @studio, user: @user)
    @studio_user.add_role!('admin')

    @api_token = ApiToken.create!(
      tenant: @tenant,
      user: @user,
      scopes: ApiToken.valid_scopes,
    )
    @headers = {
      "Authorization" => "Bearer #{@api_token.token}",
      "Accept" => "text/markdown",
      "Content-Type" => "application/json",
    }
    host! "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  def is_markdown?
    response.content_type.starts_with?("text/markdown")
  end

  test "GET webhooks index returns markdown" do
    get "/studios/#{@studio.handle}/settings/webhooks", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_match(/# Webhooks/, response.body)
  end

  test "GET new webhook returns markdown" do
    get "/studios/#{@studio.handle}/settings/webhooks/new", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_match(/# New Webhook/, response.body)
  end

  test "POST create_webhook creates a webhook" do
    post "/studios/#{@studio.handle}/settings/webhooks/new/actions/create_webhook",
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
      studio: @studio,
      name: "Show Test Webhook",
      url: "https://example.com/show",
      events: ["note.created"],
      created_by: @user,
    )

    get "/studios/#{@studio.handle}/settings/webhooks/#{webhook.id}", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_match(/# Webhook: Show Test Webhook/, response.body)
  end

  test "POST update_webhook updates a webhook" do
    webhook = Webhook.create!(
      tenant: @tenant,
      studio: @studio,
      name: "Update Test Webhook",
      url: "https://example.com/update",
      events: ["*"],
      created_by: @user,
    )

    post "/studios/#{@studio.handle}/settings/webhooks/#{webhook.id}/actions/update_webhook",
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
      studio: @studio,
      name: "Delete Test Webhook",
      url: "https://example.com/delete",
      events: ["*"],
      created_by: @user,
    )
    webhook_id = webhook.id

    post "/studios/#{@studio.handle}/settings/webhooks/#{webhook.id}/actions/delete_webhook",
      headers: @headers

    assert_response :success
    assert is_markdown?
    assert_match(/Webhook deleted successfully/, response.body)

    assert_nil Webhook.find_by(id: webhook_id)
  end

  test "POST test_webhook sends a test" do
    webhook = Webhook.create!(
      tenant: @tenant,
      studio: @studio,
      name: "Test Webhook Send",
      url: "https://example.com/test",
      events: ["*"],
      created_by: @user,
    )

    post "/studios/#{@studio.handle}/settings/webhooks/#{webhook.id}/actions/test_webhook",
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
    @studio_user.remove_role!('admin')

    get "/studios/#{@studio.handle}/settings/webhooks", headers: @headers
    assert_response :forbidden
  end

  test "webhook requires HTTPS URL" do
    post "/studios/#{@studio.handle}/settings/webhooks/new/actions/create_webhook",
      params: { name: "HTTP Webhook", url: "http://example.com/webhook", events: "*" }.to_json,
      headers: @headers

    assert_response :success  # Action still returns 200 with error message
    assert_match(/must use HTTPS/, response.body)
  end
end
