require "test_helper"

class CollectiveAutomationsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @tenant = @global_tenant
    @tenant.enable_api!
    @tenant.set_feature_flag!("automations", true)
    @collective = @global_collective
    @collective.enable_api!
    @user = @global_user

    # Make user a collective admin
    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => ["admin"] })

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

    # Automations are paid-only — upgrade the test collective so the default
    # create/update/toggle tests can reach the controller action. Tests that
    # specifically exercise the paid-tier gate downgrade back to free.
    @collective.update!(tier: Collective::TIER_PAID)
  end

  def is_markdown?
    response.content_type.starts_with?("text/markdown")
  end

  def valid_yaml
    <<~YAML
      name: "Collective Automation Test"
      description: "Test description for collective automation"

      trigger:
        type: event
        event_type: note.created

      actions:
        - type: webhook
          url: "https://example.com/webhook"
          method: POST
          payload:
            text: "New note created: {{subject.title}}"
    YAML
  end

  def create_collective_automation_rule(attrs = {})
    defaults = {
      tenant: @tenant,
      collective: @collective,
      ai_agent_id: nil,
      created_by: @user,
      name: "Test Collective Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: [{ "type" => "webhook", "url" => "https://example.com" }],
      yaml_source: valid_yaml,
    }
    AutomationRule.unscoped.create!(defaults.merge(attrs))
  end

  # === Feature flag gating ===

  test "index returns not_found when automations flag is off" do
    @tenant.set_feature_flag!("automations", false)

    get "/collectives/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :not_found
  end

  # === Index Tests ===

  test "collective admin can view automations index" do
    get "/collectives/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Automations"
  end

  test "automations are listed in index" do
    rule = create_collective_automation_rule(name: "Listed Collective Rule")

    get "/collectives/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :success
    assert_includes response.body, rule.truncated_id
    assert_includes response.body, "Listed Collective Rule"
  end

  test "index only shows collective rules, not agent rules" do
    # Create a collective rule
    collective_rule = create_collective_automation_rule(name: "Collective Rule")

    # Create an agent rule
    ai_agent = create_ai_agent(parent: @user, name: "Test Agent")
    @tenant.add_user!(ai_agent)
    agent_rule = AutomationRule.unscoped.create!(
      tenant: @tenant,
      ai_agent: ai_agent,
      created_by: @user,
      name: "Agent Rule",
      trigger_type: "event",
      trigger_config: { "event_type" => "note.created" },
      actions: { "task" => "Test task" },
    )

    get "/collectives/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :success
    assert_includes response.body, "Collective Rule"
    assert_not_includes response.body, "Agent Rule"
  end

  # === New Page Tests ===

  test "collective admin can view new automation page" do
    get "/collectives/#{@collective.handle}/settings/automations/new", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "New Automation"
  end

  # === Create Tests ===

  test "collective admin can create automation" do
    assert_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: valid_yaml }.to_json,
        headers: @headers
    end

    assert_response :success
    assert is_markdown?
    assert_includes response.body, "created successfully"

    rule = AutomationRule.unscoped.order(created_at: :desc).first
    assert_equal @collective.id, rule.collective_id
    assert_nil rule.ai_agent_id
    assert_equal @user, rule.created_by
    assert_equal "Collective Automation Test", rule.name
    assert_equal "event", rule.trigger_type
    assert_equal "note.created", rule.event_type
    assert rule.collective_rule?
  end

  test "create requires yaml_source" do
    assert_no_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: {}.to_json,
        headers: @headers
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "YAML configuration is required"
  end

  test "create validates yaml for collective rules (requires actions or task)" do
    # Missing both task and actions - should fail validation
    invalid_yaml = <<~YAML
      name: "Missing actions"
      description: "This is invalid - no actions defined"

      trigger:
        type: event
        event_type: note.created
    YAML

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: invalid_yaml }.to_json,
        headers: @headers
    end

    assert_response :unprocessable_entity
    # Should require either actions or task
    assert_includes response.body, "actions is required"
  end

  # === Show Page Tests ===

  test "collective admin can view automation" do
    rule = create_collective_automation_rule(
      name: "My Collective Automation",
      description: "Test description",
    )

    get "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "My Collective Automation"
    assert_includes response.body, "note.created"
  end

  # === Edit Page Tests ===

  test "collective admin can view edit page" do
    rule = create_collective_automation_rule(name: "Editable Rule")

    get "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/edit", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Edit"
    assert_includes response.body, rule.yaml_source
  end

  # === Update Tests ===

  test "collective admin can update automation" do
    rule = create_collective_automation_rule(name: "Original Name")

    updated_yaml = <<~YAML
      name: "Updated Name"
      description: "Updated description"

      trigger:
        type: event
        event_type: comment.created

      actions:
        - type: webhook
          url: "https://updated.example.com/webhook"
          method: POST
    YAML

    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/update_automation_rule",
      params: { yaml_source: updated_yaml }.to_json,
      headers: @headers

    assert_response :success
    assert_includes response.body, "updated successfully"

    rule.reload
    assert_equal "Updated Name", rule.name
    assert_equal "comment.created", rule.event_type
  end

  # === Delete Tests ===

  test "collective admin can delete automation" do
    rule = create_collective_automation_rule(name: "To Delete")

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/delete_automation_rule",
        headers: @headers
    end

    assert_response :success
    assert_includes response.body, "deleted"
    rule.reload
    assert_not_nil rule.deleted_at

    # Soft-deleted rules disappear from the automations index.
    get "/collectives/#{@collective.handle}/settings/automations", headers: @headers
    assert_not_includes response.body, "To Delete"
  end

  # === Toggle Tests ===

  test "collective admin can toggle automation enabled state" do
    rule = create_collective_automation_rule(name: "Toggle Test", enabled: true)

    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule",
      headers: @headers

    assert_response :success
    assert_includes response.body, "disabled"
    rule.reload
    assert_not rule.enabled?

    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule",
      headers: @headers

    assert_response :success
    assert_includes response.body, "enabled"
    rule.reload
    assert rule.enabled?
  end

  # === Runs Page Tests ===

  test "collective admin can view automation run history" do
    rule = create_collective_automation_rule(name: "Run History Test")

    AutomationRuleRun.unscoped.create!(
      tenant: @tenant,
      collective: @collective,
      automation_rule: rule,
      trigger_source: "event",
      status: "completed",
    )

    get "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/runs", headers: @headers
    assert_response :success
    assert is_markdown?
    assert_includes response.body, "Run History"
    assert_includes response.body, "completed"
  end

  # === Authorization Tests ===

  test "non-admin cannot view automations" do
    # Remove admin role
    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => [] })

    get "/collectives/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :forbidden
    assert_includes response.body, "admin"
  end

  test "non-admin cannot create automation" do
    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => [] })

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: valid_yaml }.to_json,
        headers: @headers
    end

    assert_response :forbidden
  end

  test "non-admin cannot delete automation" do
    rule = create_collective_automation_rule(name: "Protected Rule")

    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => [] })

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/delete_automation_rule",
        headers: @headers
    end

    assert_response :forbidden
  end

  # === Automator role ===
  #
  # The automator role grants the full automation-management surface that
  # admins have — it relaxes WHO passes the gate, nothing else. The paid-tier
  # gate is orthogonal and still applies.

  def make_automator!
    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => ["automator"] })
  end

  test "an automator can view automations index" do
    make_automator!

    get "/collectives/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :success
  end

  test "an automator can create an automation" do
    make_automator!

    assert_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: valid_yaml }.to_json,
        headers: @headers
    end

    assert_response :success
  end

  test "an automator can toggle an automation" do
    rule = create_collective_automation_rule(name: "Toggle Target")
    make_automator!

    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule",
      headers: @headers

    assert_response :success
    assert_not rule.reload.enabled
  end

  test "the moderator role grants no automation access" do
    member = @collective.collective_members.find_by(user: @user)
    member.update!(settings: { "roles" => ["moderator"] })

    get "/collectives/#{@collective.handle}/settings/automations", headers: @headers
    assert_response :forbidden
  end

  test "the paid-tier gate still applies to automators" do
    # setup_gate_test switches to session auth on a free-tier collective with
    # stripe_billing on — the arrangement where the tier gate actually bites.
    setup_gate_test
    make_automator!

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: valid_yaml }
    end

    assert_match(/paid plan/i, flash[:error].to_s.presence || response.body)
  end

  # === Webhook Trigger Type Tests ===

  test "can create automation with webhook trigger type" do
    webhook_yaml = <<~YAML
      name: "Webhook Triggered Automation"
      description: "Triggered by external webhook"

      trigger:
        type: webhook

      actions:
        - type: internal_action
          action: create_note
          params:
            text: "Webhook received!"
    YAML

    assert_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: webhook_yaml }.to_json,
        headers: @headers
    end

    assert_response :success

    rule = AutomationRule.unscoped.order(created_at: :desc).first
    assert_equal "webhook", rule.trigger_type
    assert rule.webhook_path.present?
    assert rule.webhook_secret.present?
  end

  # === Schedule Trigger Type Tests ===

  test "can create automation with schedule trigger type" do
    schedule_yaml = <<~YAML
      name: "Scheduled Automation"
      description: "Runs on a schedule"

      trigger:
        type: schedule
        cron: "0 9 * * *"
        timezone: "America/Los_Angeles"

      actions:
        - type: webhook
          url: "https://example.com/daily"
          method: POST
    YAML

    assert_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: schedule_yaml }.to_json,
        headers: @headers
    end

    assert_response :success

    rule = AutomationRule.unscoped.order(created_at: :desc).first
    assert_equal "schedule", rule.trigger_type
    assert_equal "0 9 * * *", rule.cron_expression
    assert_equal "America/Los_Angeles", rule.timezone
  end

  # === Paid-tier gate ===
  #
  # Automations require the collective to be on the paid tier. The owner's
  # Stripe billing setup is no longer the gate — tier is the source of
  # truth. These tests downgrade the collective back to free and verify
  # actions are refused with a "paid plan" error.
  #
  # They use session auth (sign_in_as) rather than the bearer token from
  # setup. The bearer token would itself make the user billable via the
  # "humans-with-tokens" rule, which would force them through the
  # application-level billing gate before reaching the per-action gate
  # under test.

  test "execute_toggle blocks enabling a disabled rule when collective is free" do
    setup_gate_test
    rule = create_collective_automation_rule(name: "Gate Toggle", enabled: false)

    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule"

    rule.reload
    assert_not rule.enabled?, "rule should remain disabled when collective is free"
    assert_response :redirect
    assert_match(/paid plan/i, flash[:error].to_s)
  end

  test "execute_toggle allows enabling when collective is on the paid tier" do
    setup_gate_test
    @collective.update!(tier: Collective::TIER_PAID)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)
    rule = create_collective_automation_rule(name: "Gate Toggle OK", enabled: false)

    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule"

    assert_response :redirect
    assert rule.reload.enabled?
    assert_match(/enabled/i, flash[:notice].to_s)
  end

  test "execute_toggle always allows disabling regardless of tier" do
    setup_gate_test
    # Collective starts at free in setup_gate_test; force-create an enabled
    # rule (a leftover from before a downgrade, say) and verify the disable
    # path goes through.
    rule = create_collective_automation_rule(name: "Gate Disable", enabled: true)

    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule"

    assert_response :redirect
    assert_not rule.reload.enabled?
    assert_match(/disabled/i, flash[:notice].to_s)
  end

  test "execute_create blocks creating an automation when collective is free" do
    setup_gate_test

    assert_no_difference "AutomationRule.unscoped.count" do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: valid_yaml }, headers: { "Accept" => "text/markdown" }
    end
    assert_includes response.body.downcase, "paid plan"
  end

  test "execute_create allows creating when collective is on the paid tier" do
    setup_gate_test
    @collective.update!(tier: Collective::TIER_PAID)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)

    assert_difference "AutomationRule.unscoped.count", 1 do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: valid_yaml }, headers: { "Accept" => "text/markdown" }
    end
  end

  test "execute_update blocks editing when collective is free" do
    setup_gate_test
    rule = create_collective_automation_rule(name: "Edit Other", enabled: false)
    edited_yaml = valid_yaml.sub('"Collective Automation Test"', '"Renamed"')

    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/update_automation_rule",
      params: { yaml_source: edited_yaml }, headers: { "Accept" => "text/markdown" }

    assert_includes response.body.downcase, "paid plan"
    assert_equal "Edit Other", rule.reload.name, "rule should be unchanged"
  end

  test "GET /new redirects with error on a free collective (billing tenant)" do
    setup_gate_test
    # @collective is downgraded to free by setup_gate_test
    get "/collectives/#{@collective.handle}/settings/automations/new"

    assert_response :redirect
    assert_match %r{/settings/automations\z}, response.location
    assert_match(/paid plan/i, flash[:error].to_s)
  end

  test "GET /new renders the form on a paid collective (billing tenant)" do
    setup_gate_test
    @collective.update!(tier: Collective::TIER_PAID)
    StripeCustomer.create!(billable: @user, stripe_id: "cus_#{SecureRandom.hex(4)}", active: true)

    get "/collectives/#{@collective.handle}/settings/automations/new"

    assert_response :success
    assert_includes response.body, "yaml_source"
  end

  # Regression coverage for the Turbo + render_action_* fix: HTML form
  # submits used to render 200-with-HTML, which Turbo Drive silently dropped
  # so the user saw "nothing happened." HTML must now redirect+flash; the md
  # API contract stays the same.
  test "render_action_success: HTML returns redirect+flash; md returns 200 with action body" do
    rule = create_collective_automation_rule(name: "Format Distinction")
    @api_token.destroy
    sign_in_as(@user, tenant: @tenant)

    # HTML path: redirect + flash[:notice]
    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule"
    assert_response :redirect, "HTML form submit must redirect (not 200) so Turbo follows the response"
    assert flash[:notice].present?, "HTML response must set a flash so the user gets feedback"

    # md path: 200 with structured Action Success body
    post "/collectives/#{@collective.handle}/settings/automations/#{rule.truncated_id}/actions/toggle_automation_rule",
      headers: { "Accept" => "text/markdown" }
    assert_response :success
    assert response.content_type.starts_with?("text/markdown")
    assert_includes response.body, "Action Success"
  end

  test "render_action_error: HTML returns redirect+flash[:error]; md returns 422 with action error body" do
    @api_token.destroy
    sign_in_as(@user, tenant: @tenant)

    # Submit a create with invalid yaml so render_action_error fires.
    invalid_yaml = "name: missing actions and task"

    post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
      params: { yaml_source: invalid_yaml }
    assert_response :redirect, "HTML error response must redirect+flash, not render 200-with-HTML"
    assert flash[:error].present?, "HTML error response must surface the error via flash"

    post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
      params: { yaml_source: invalid_yaml }, headers: { "Accept" => "text/markdown" }
    assert_response :unprocessable_entity, "md error contract: real status code so stateless clients can branch on outcome"
    assert_includes response.body, "Action Error"
  end

  # Self-hosted (non-billing) tenants have no tier model. Free-tier
  # collectives there must still allow automation create/toggle — the
  # controller gate uses tier_unlocks_paid_features?, not paid_tier?.
  test "self-hosted: free collective allows automation create without paid tier" do
    # No stripe_billing on tenant; collective starts at tier=free per setup.
    @collective.update!(tier: Collective::TIER_FREE)
    @api_token.destroy
    sign_in_as(@user, tenant: @tenant)

    assert_difference "AutomationRule.unscoped.count", 1 do
      post "/collectives/#{@collective.handle}/settings/automations/new/actions/create_automation_rule",
        params: { yaml_source: valid_yaml }, headers: { "Accept" => "text/markdown" }
    end
    assert_response :success
  end

  private

  # Common gate-test setup: enable stripe_billing on tenant, delete the setup
  # bearer token so it doesn't make the user billable, downgrade the
  # collective back to free (setup defaults to paid), sign in via session.
  def setup_gate_test
    FeatureFlagService.config["stripe_billing"] ||= {}
    FeatureFlagService.config["stripe_billing"]["app_enabled"] = true
    @tenant.enable_feature_flag!("stripe_billing")
    @api_token.destroy
    @collective.update!(tier: Collective::TIER_FREE)
    sign_in_as(@user, tenant: @tenant)
  end
end
