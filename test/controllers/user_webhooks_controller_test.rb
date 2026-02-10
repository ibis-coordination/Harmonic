require "test_helper"

class UserWebhooksControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @superagent = @global_superagent
    @superagent.enable_api!
    @user = @global_user

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

  # === Index Tests ===

  test "user can view their own webhooks" do
    get "/u/#{@user.handle}/settings/webhooks", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Webhooks for #{@user.handle}"
  end

  test "user webhooks are listed in index" do
    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: @user,
      name: "Listed Webhook",
      url: "https://example.com/listed",
      events: ["reminders.delivered"],
      created_by: @user,
    )

    get "/u/#{@user.handle}/settings/webhooks", headers: @headers
    assert_response :success
    assert_includes response.body, webhook.truncated_id
    assert_includes response.body, "Listed Webhook"
  end

  # === New Page Tests ===

  test "user can view new webhook page" do
    get "/u/#{@user.handle}/settings/webhooks/new", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "New Webhook"
  end

  # === Create Tests ===

  test "user can create a webhook for themselves" do
    assert_difference "Webhook.unscoped.count" do
      post "/u/#{@user.handle}/settings/webhooks/new/actions/create_webhook",
        params: { url: "https://example.com/webhook", events: "reminders.delivered" }.to_json,
        headers: @headers
    end

    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Webhook created"

    webhook = Webhook.unscoped.order(created_at: :desc).first
    assert_equal @user, webhook.user
    assert_equal @user, webhook.created_by
    assert_nil webhook.superagent
  end

  test "create_webhook requires URL" do
    post "/u/#{@user.handle}/settings/webhooks/new/actions/create_webhook",
      params: { events: "reminders.delivered" }.to_json,
      headers: @headers

    assert_response :success  # Action returns success even on error (renders error message)
    assert_includes response.body, "URL is required"
  end

  test "create defaults to notifications.delivered event" do
    post "/u/#{@user.handle}/settings/webhooks/new/actions/create_webhook",
      params: { url: "https://example.com/default-events" }.to_json,
      headers: @headers

    assert_response :success
    webhook = Webhook.unscoped.order(created_at: :desc).first
    assert_equal ["notifications.delivered"], webhook.events
  end

  test "create accepts custom events" do
    post "/u/#{@user.handle}/settings/webhooks/new/actions/create_webhook",
      params: { url: "https://example.com/custom", events: "reminders.delivered,custom.event" }.to_json,
      headers: @headers

    assert_response :success
    webhook = Webhook.unscoped.order(created_at: :desc).first
    assert_includes webhook.events, "reminders.delivered"
    assert_includes webhook.events, "custom.event"
  end

  # === Show Page Tests ===

  test "user can view their own webhook" do
    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: @user,
      name: "My Webhook",
      url: "https://example.com/show",
      events: ["reminders.delivered"],
      created_by: @user,
    )

    get "/u/#{@user.handle}/settings/webhooks/#{webhook.truncated_id}", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Webhook: My Webhook"
    assert_includes response.body, "delete_webhook()"
    assert_includes response.body, "test_webhook()"
  end

  # === Delete Tests ===

  test "user can delete their own webhook" do
    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: @user,
      name: "My webhook",
      url: "https://example.com/hook",
      events: ["reminders.delivered"],
      created_by: @user,
    )

    assert_difference "Webhook.unscoped.count", -1 do
      post "/u/#{@user.handle}/settings/webhooks/#{webhook.truncated_id}/actions/delete_webhook",
        headers: @headers
    end

    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Webhook deleted"
  end

  # === Test Webhook Tests ===

  test "user can test their own webhook" do
    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: @user,
      name: "Test webhook",
      url: "https://example.com/test-hook",
      events: ["reminders.delivered"],
      created_by: @user,
    )

    assert_enqueued_with(job: WebhookDeliveryJob) do
      post "/u/#{@user.handle}/settings/webhooks/#{webhook.truncated_id}/actions/test_webhook",
        headers: @headers
    end

    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Test webhook sent"
  end

  # === AiAgent Webhooks Tests ===

  test "parent can view ai_agent webhooks" do
    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent")
    @tenant.add_user!(ai_agent)

    get "/u/#{ai_agent.handle}/settings/webhooks", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Webhooks for #{ai_agent.handle}"
    assert_includes response.body, "You are managing webhooks for"
  end

  test "parent can create webhook for ai_agent" do
    ai_agent = create_ai_agent(parent: @user, name: "Webhook AiAgent")
    @tenant.add_user!(ai_agent)

    assert_difference "Webhook.unscoped.count" do
      post "/u/#{ai_agent.handle}/settings/webhooks/new/actions/create_webhook",
        params: { url: "https://example.com/ai_agent-webhook" }.to_json,
        headers: @headers
    end

    assert_response :success

    webhook = Webhook.unscoped.order(created_at: :desc).first
    assert_equal ai_agent, webhook.user
    assert_equal @user, webhook.created_by  # Parent created it
  end

  test "parent can delete ai_agent webhook" do
    ai_agent = create_ai_agent(parent: @user, name: "Delete AiAgent")
    @tenant.add_user!(ai_agent)

    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: ai_agent,
      name: "AiAgent webhook",
      url: "https://example.com/ai_agent-hook",
      events: ["reminders.delivered"],
      created_by: @user,
    )

    assert_difference "Webhook.unscoped.count", -1 do
      post "/u/#{ai_agent.handle}/settings/webhooks/#{webhook.truncated_id}/actions/delete_webhook",
        headers: @headers
    end

    assert_response :success
    assert_includes response.body, "Webhook deleted"
  end

  test "parent can test ai_agent webhook" do
    ai_agent = create_ai_agent(parent: @user, name: "Test AiAgent")
    @tenant.add_user!(ai_agent)

    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: ai_agent,
      name: "AiAgent test webhook",
      url: "https://example.com/ai_agent-test",
      events: ["reminders.delivered"],
      created_by: @user,
    )

    assert_enqueued_with(job: WebhookDeliveryJob) do
      post "/u/#{ai_agent.handle}/settings/webhooks/#{webhook.truncated_id}/actions/test_webhook",
        headers: @headers
    end

    assert_response :success
    assert_includes response.body, "Test webhook sent"
  end

  # === Authorization Tests ===

  test "non-parent cannot view other user webhooks" do
    other_user = create_user
    @tenant.add_user!(other_user)

    get "/u/#{other_user.handle}/settings/webhooks", headers: @headers
    assert_response :forbidden
    assert_includes response.body, "You don't have permission"
  end

  test "non-parent cannot create webhook for other user" do
    other_user = create_user
    @tenant.add_user!(other_user)

    assert_no_difference "Webhook.unscoped.count" do
      post "/u/#{other_user.handle}/settings/webhooks/new/actions/create_webhook",
        params: { url: "https://example.com/bad" }.to_json,
        headers: @headers
    end

    assert_response :forbidden
  end

  test "non-parent cannot delete other user webhook" do
    other_user = create_user
    @tenant.add_user!(other_user)

    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: other_user,
      name: "Other user webhook",
      url: "https://example.com/other-hook",
      events: ["reminders.delivered"],
      created_by: other_user,
    )

    assert_no_difference "Webhook.unscoped.count" do
      post "/u/#{other_user.handle}/settings/webhooks/#{webhook.truncated_id}/actions/delete_webhook",
        headers: @headers
    end

    assert_response :forbidden
  end

  test "non-parent cannot test other user webhook" do
    other_user = create_user
    @tenant.add_user!(other_user)

    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: other_user,
      name: "Other user webhook",
      url: "https://example.com/other-test",
      events: ["reminders.delivered"],
      created_by: other_user,
    )

    post "/u/#{other_user.handle}/settings/webhooks/#{webhook.truncated_id}/actions/test_webhook",
      headers: @headers

    assert_response :forbidden
  end

  # === Bug Reproduction Tests ===

  test "webhook show page displays event type correctly (not 'unknown')" do
    # Create a webhook delivery with an event from a different superagent context
    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: @user,
      name: "Event Type Test",
      url: "https://example.com/event-test",
      events: ["notifications.delivered"],
      created_by: @user,
    )

    # Create an event in a specific superagent context
    Superagent.scope_thread_to_superagent(subdomain: @tenant.subdomain, handle: @superagent.handle)
    event = Event.create!(
      tenant: @tenant,
      superagent: @superagent,
      event_type: "notifications.delivered",
      actor: @user,
      metadata: { notification_type: "mention" },
    )

    # Create a delivery for this webhook
    delivery = WebhookDelivery.create!(
      webhook: webhook,
      event: event,
      status: "success",
      attempt_count: 1,
      request_body: "{}",
      response_code: 200,
    )
    Superagent.clear_thread_scope

    # Now view the webhook page - the event type should be shown, not "unknown"
    get "/u/#{@user.handle}/settings/webhooks/#{webhook.truncated_id}", headers: @headers
    assert_response :success

    # The event type should be shown, not "unknown"
    assert_includes response.body, "notifications.delivered"
    assert_not_includes response.body, "`unknown`"
  end
end
