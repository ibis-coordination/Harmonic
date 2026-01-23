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

  # === Own Webhooks Tests ===

  test "user can view their own webhooks" do
    get "/u/#{@user.handle}/settings/webhooks", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Webhooks for #{@user.handle}"
  end

  test "user can create a webhook for themselves" do
    assert_difference "Webhook.unscoped.count" do
      post "/u/#{@user.handle}/settings/webhooks/actions/create",
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
      post "/u/#{@user.handle}/settings/webhooks/actions/delete",
        params: { id: webhook.truncated_id }.to_json,
        headers: @headers
    end

    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Webhook deleted"
  end

  test "create_user_webhook requires URL" do
    post "/u/#{@user.handle}/settings/webhooks/actions/create",
      params: { events: "reminders.delivered" }.to_json,
      headers: @headers

    assert_response :success  # Action returns success even on error (renders error message)
    assert_includes response.body, "URL is required"
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

  # === Subagent Webhooks Tests ===

  test "parent can view subagent webhooks" do
    subagent = create_subagent(parent: @user, name: "Test Subagent")
    @tenant.add_user!(subagent)

    get "/u/#{subagent.handle}/settings/webhooks", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Webhooks for #{subagent.handle}"
    assert_includes response.body, "You are managing webhooks for"
  end

  test "parent can create webhook for subagent" do
    subagent = create_subagent(parent: @user, name: "Webhook Subagent")
    @tenant.add_user!(subagent)

    assert_difference "Webhook.unscoped.count" do
      post "/u/#{subagent.handle}/settings/webhooks/actions/create",
        params: { url: "https://example.com/subagent-webhook" }.to_json,
        headers: @headers
    end

    assert_response :success

    webhook = Webhook.unscoped.order(created_at: :desc).first
    assert_equal subagent, webhook.user
    assert_equal @user, webhook.created_by  # Parent created it
  end

  test "parent can delete subagent webhook" do
    subagent = create_subagent(parent: @user, name: "Delete Subagent")
    @tenant.add_user!(subagent)

    webhook = Webhook.unscoped.create!(
      tenant: @tenant,
      user: subagent,
      name: "Subagent webhook",
      url: "https://example.com/subagent-hook",
      events: ["reminders.delivered"],
      created_by: @user,
    )

    assert_difference "Webhook.unscoped.count", -1 do
      post "/u/#{subagent.handle}/settings/webhooks/actions/delete",
        params: { id: webhook.truncated_id }.to_json,
        headers: @headers
    end

    assert_response :success
    assert_includes response.body, "Webhook deleted"
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
      post "/u/#{other_user.handle}/settings/webhooks/actions/create",
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
      post "/u/#{other_user.handle}/settings/webhooks/actions/delete",
        params: { id: webhook.truncated_id }.to_json,
        headers: @headers
    end

    assert_response :forbidden
  end

  test "delete returns error for nonexistent webhook" do
    post "/u/#{@user.handle}/settings/webhooks/actions/delete",
      params: { id: "nonexist" }.to_json,
      headers: @headers

    assert_response :success  # Action renders error message, not HTTP error
    assert_includes response.body, "Webhook not found"
  end

  # === Default Events Test ===

  test "create defaults to reminders.delivered event" do
    post "/u/#{@user.handle}/settings/webhooks/actions/create",
      params: { url: "https://example.com/default-events" }.to_json,
      headers: @headers

    assert_response :success
    webhook = Webhook.unscoped.order(created_at: :desc).first
    assert_equal ["reminders.delivered"], webhook.events
  end

  test "create accepts custom events" do
    post "/u/#{@user.handle}/settings/webhooks/actions/create",
      params: { url: "https://example.com/custom", events: "reminders.delivered,custom.event" }.to_json,
      headers: @headers

    assert_response :success
    webhook = Webhook.unscoped.order(created_at: :desc).first
    assert_includes webhook.events, "reminders.delivered"
    assert_includes webhook.events, "custom.event"
  end
end
