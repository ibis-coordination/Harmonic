require "test_helper"

class HarmonicBridgeSetupTest < ActiveSupport::TestCase
  def setup
    @tenant, _collective, @human = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    @agent = create_ai_agent(parent: @human, name: "Agent", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(@agent)
  end

  def build_setup(**overrides)
    HarmonicBridgeSetup.new(
      tenant: @tenant,
      ai_agent_user: @agent,
      created_by_user: @human,
      **overrides
    )
  end

  # ---------- create + defaults ----------

  test "create: assigns a high-entropy public_id" do
    s = build_setup
    s.save!
    assert s.public_id.present?
    # 24-byte url-safe base64 is at least 30 chars
    assert s.public_id.length >= 30, "public_id should be high-entropy"
  end

  test "create: assigns expires_at ~15 minutes in the future" do
    s = build_setup
    s.save!
    assert_in_delta 15.minutes.from_now.to_i, s.expires_at.to_i, 5
  end

  test "create: defaults events_recommended to notifications + reminders" do
    s = build_setup
    s.save!
    assert_equal ["notifications.delivered", "reminders.delivered"], s.events_recommended
  end

  test "create: caller-provided events_recommended is preserved" do
    s = build_setup(events_recommended: ["notifications.delivered"])
    s.save!
    assert_equal ["notifications.delivered"], s.events_recommended
  end

  test "validates uniqueness of public_id within a tenant" do
    first = build_setup
    first.save!
    duplicate = build_setup(public_id: first.public_id)
    assert_not duplicate.valid?
    assert duplicate.errors[:public_id].any?
  end

  # ---------- redeemable? ----------

  test "redeemable?: true when not redeemed and not expired" do
    s = build_setup
    s.save!
    assert s.redeemable?
  end

  test "redeemable?: false when redeemed_at is set" do
    s = build_setup
    s.save!
    s.update!(redeemed_at: Time.current)
    assert_not s.redeemable?
  end

  test "redeemable?: false when expired" do
    s = build_setup(expires_at: 1.minute.ago)
    s.save!
    assert_not s.redeemable?
  end

  # ---------- webhook_registerable? ----------

  test "webhook_registerable?: true when redeemed but not yet webhook-registered" do
    s = build_setup
    s.save!
    s.update!(redeemed_at: Time.current)
    assert s.webhook_registerable?
  end

  test "webhook_registerable?: false when not yet redeemed" do
    s = build_setup
    s.save!
    assert_not s.webhook_registerable?
  end

  test "webhook_registerable?: false when already webhook-registered" do
    s = build_setup
    s.save!
    s.update!(redeemed_at: Time.current, webhook_registered_at: Time.current)
    assert_not s.webhook_registerable?
  end

  test "webhook_registerable?: false when expired (even if redeemed)" do
    s = build_setup(expires_at: 1.minute.ago)
    s.save!
    s.update_columns(redeemed_at: Time.current)
    assert_not s.webhook_registerable?
  end

  # ---------- mark_redeemed! ----------

  test "mark_redeemed!: sets redeemed_at and mints no credentials" do
    s = build_setup
    s.save!
    s.mark_redeemed!

    assert s.redeemed_at.present?
    assert_nil s.api_token
    assert_nil s.automation_rule
    assert_equal 0, @agent.api_tokens.count, "no token minted on GET"
  end

  test "mark_redeemed!: raises if already redeemed" do
    s = build_setup
    s.save!
    s.mark_redeemed!
    assert_raises(HarmonicBridgeSetup::Redeemed) { s.mark_redeemed! }
  end

  test "mark_redeemed!: raises if expired" do
    s = build_setup(expires_at: 1.minute.ago)
    s.save!
    assert_raises(HarmonicBridgeSetup::Expired) { s.mark_redeemed! }
  end

  test "mark_redeemed!: two in-memory instances both call it, only one wins (lock + post-lock re-check)" do
    # Simulates two concurrent GET requests that both loaded the row before
    # either committed redemption. with_lock + reload + re-check inside
    # mark_redeemed! must make exactly one win; the loser raises Redeemed.
    s = build_setup
    s.save!
    s_copy = HarmonicBridgeSetup.find(s.id)

    s.mark_redeemed!
    assert_raises(HarmonicBridgeSetup::Redeemed) { s_copy.mark_redeemed! }
  end

  # ---------- complete! ----------

  test "complete!: atomically mints token + creates AutomationRule + returns both credentials" do
    s = build_setup
    s.save!
    s.mark_redeemed!

    webhook_url = "https://agent.example.test/webhook/#{@agent.tenant_users.find_by(tenant_id: @tenant.id).handle}"
    credentials = s.complete!(webhook_url: webhook_url, events: ["notifications.delivered"])

    assert credentials[:harmonic_token].present?
    assert credentials[:signing_secret].present?
    assert_match(/\A[a-f0-9]+\z|\A[A-Za-z0-9_-]+\z/, credentials[:harmonic_token], "plaintext should be a credential string")

    s.reload
    token = s.api_token
    assert_not_nil token
    assert_equal @agent.id, token.user_id
    assert token.mcp_only?, "token should be mcp_only"
    assert token.scopes.include?("read:all")
    assert token.scopes.include?("create:all")

    rule = s.automation_rule
    assert_not_nil rule
    assert_equal @agent.id, rule.ai_agent_id
    assert_equal "event", rule.trigger_type
    assert_equal ["notifications.delivered"], rule.trigger_config["event_types"]
    assert_equal webhook_url, rule.actions["webhook_url"]
    assert rule.enabled?
    assert_equal credentials[:signing_secret], rule.webhook_secret
    assert s.webhook_registered_at.present?
  end

  test "complete!: raises if not yet redeemed" do
    s = build_setup
    s.save!
    assert_raises(HarmonicBridgeSetup::NotYetRedeemed) do
      s.complete!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    end
  end

  test "complete!: raises if already completed" do
    s = build_setup
    s.save!
    s.mark_redeemed!
    s.complete!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    assert_raises(HarmonicBridgeSetup::WebhookAlreadyRegistered) do
      s.complete!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    end
  end

  test "complete!: raises if expired" do
    s = build_setup
    s.save!
    s.mark_redeemed!
    s.update_columns(expires_at: 1.minute.ago)
    assert_raises(HarmonicBridgeSetup::Expired) do
      s.complete!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    end
  end

  test "complete!: two in-memory instances do not double-complete (lock + post-lock re-check)" do
    # Simulates two concurrent POSTs that both loaded the row after the GET
    # committed `redeemed_at` but before either committed completion. with_lock
    # + reload + re-check inside complete! must make exactly one win; the loser
    # raises WebhookAlreadyRegistered and mints no token / creates no rule.
    s = build_setup
    s.save!
    s.mark_redeemed!
    s_copy = HarmonicBridgeSetup.find(s.id)

    s.complete!(webhook_url: "https://first.example/y", events: ["notifications.delivered"])

    assert_raises(HarmonicBridgeSetup::WebhookAlreadyRegistered) do
      s_copy.complete!(webhook_url: "https://second.example/y", events: ["notifications.delivered"])
    end

    assert_equal 1, @agent.api_tokens.count, "exactly one token across both calls"
    assert_equal 1, AutomationRule.where(ai_agent_id: @agent.id).count, "exactly one AutomationRule across both calls"
  end

  # ---------- revert_completion! ----------

  test "revert_completion!: destroys both the token and the AutomationRule, returns setup to retryable state" do
    s = build_setup
    s.save!
    s.mark_redeemed!
    s.complete!(webhook_url: "https://x/y", events: ["notifications.delivered"])

    rule_id = s.automation_rule.id
    token_id = s.api_token.id

    s.revert_completion!

    assert_nil s.automation_rule
    assert_nil s.api_token
    assert_nil s.webhook_registered_at
    assert s.redeemed_at.present?, "redeemed_at stays set; only completion is reverted"
    assert_nil AutomationRule.find_by(id: rule_id)
    assert_nil ApiToken.find_by(id: token_id)

    # And the setup is retryable: a fresh complete! should work
    credentials = s.complete!(webhook_url: "https://other/y", events: ["notifications.delivered"])
    assert credentials[:harmonic_token].present?
  end
end
