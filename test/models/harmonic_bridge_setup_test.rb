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

  test "create: rejected when the agent already has a notification webhook" do
    # Simulate an existing notification webhook (manual or prior bridge setup
    # that succeeded). New bridge setup is blocked so the user has to clean
    # up the old subscription first instead of failing partway through `add`.
    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @agent,
      created_by: @human,
      name: "existing-webhook",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "webhook_url" => "https://existing.example/webhook" },
      enabled: true
    )

    s = build_setup
    assert_not s.valid?
    assert_match(/already has a notification webhook/, s.errors[:base].first.to_s)
  end

  test "create: ALLOWED when the agent has only a pending (URL-less) rule from an earlier setup" do
    # A previous setup that GETted but never POSTed left a rule with no
    # webhook_url. That doesn't count as an active subscription — the user
    # should be able to start a fresh setup.
    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @agent,
      created_by: @human,
      name: "pending-from-prior-setup",
      trigger_type: "event",
      trigger_config: { "event_types" => ["notifications.delivered"] },
      actions: { "payload_template" => {} },
      enabled: false
    )

    s = build_setup
    assert s.valid?, "pending (URL-less) rules don't count as active webhooks: #{s.errors.full_messages}"
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

  test "webhook_registerable?: true when redeemed with a pending AutomationRule and no webhook yet" do
    s = build_setup
    s.save!
    s.redeem!
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
    s.redeem!
    s.update!(webhook_registered_at: Time.current)
    assert_not s.webhook_registerable?
  end

  test "webhook_registerable?: false when expired (even if redeemed)" do
    s = build_setup(expires_at: 1.minute.ago)
    s.save!
    s.update_columns(redeemed_at: Time.current)
    assert_not s.webhook_registerable?
  end

  test "webhook_registerable?: false when the AutomationRule has been destroyed (post-revert)" do
    s = build_setup
    s.save!
    s.update!(redeemed_at: Time.current, automation_rule: nil)
    assert_not s.webhook_registerable?, "post-revert setups are no longer POSTable"
  end

  # ---------- redeem! ----------

  test "redeem!: mints an MCP token + creates a pending AutomationRule, returns both plaintexts" do
    s = build_setup
    s.save!
    credentials = s.redeem!

    assert credentials[:harmonic_token].present?
    assert credentials[:signing_secret].present?
    assert_match(/\A[a-f0-9]+\z|\A[A-Za-z0-9_-]+\z/, credentials[:harmonic_token])

    s.reload
    assert s.redeemed_at.present?

    token = s.api_token
    assert_not_nil token
    assert_equal @agent.id, token.user_id
    assert token.mcp_type?, "token should be mcp type"
    assert token.scopes.include?("read:all")
    assert token.scopes.include?("create:all")

    rule = s.automation_rule
    assert_not_nil rule
    assert_equal credentials[:signing_secret], rule.webhook_secret,
                 "signing secret comes from the rule's own webhook_secret field"
    assert_equal false, rule.enabled?, "rule starts disabled until POST"
    assert_nil rule.actions["webhook_url"], "no URL until POST"
    assert_equal @agent.id, rule.ai_agent_id
  end

  test "redeem!: raises if already redeemed" do
    s = build_setup
    s.save!
    s.redeem!
    assert_raises(HarmonicBridgeSetup::Redeemed) { s.redeem! }
  end

  test "redeem!: raises if expired" do
    s = build_setup(expires_at: 1.minute.ago)
    s.save!
    assert_raises(HarmonicBridgeSetup::Expired) { s.redeem! }
  end

  test "redeem!: two in-memory instances do not double-mint (lock + post-lock re-check)" do
    # Simulates two concurrent GETs that both loaded the row before either
    # committed redemption. with_lock + reload + re-check inside redeem! must
    # make exactly one win; the loser raises Redeemed.
    s = build_setup
    s.save!
    s_copy = HarmonicBridgeSetup.find(s.id)

    s.redeem!
    assert_raises(HarmonicBridgeSetup::Redeemed) { s_copy.redeem! }
    assert_equal 1, @agent.api_tokens.count, "exactly one token minted across both calls"
    assert_equal 1, AutomationRule.where(ai_agent_id: @agent.id).count, "exactly one rule across both calls"
  end

  test "redeem!: does NOT block on unrelated automation rules for the same agent" do
    # An agent can have scheduled-task rules, collective-wide rules, etc.
    # that aren't notification webhooks. Those shouldn't block a bridge setup.
    AutomationRule.create!(
      tenant: @tenant,
      ai_agent: @agent,
      created_by: @human,
      name: "agent's scheduled job",
      trigger_type: "schedule",
      trigger_config: { "cron" => "0 9 * * *" },
      actions: { "task" => "say hi" },
      enabled: true
    )

    s = build_setup
    s.save!
    assert_nothing_raised { s.redeem! }
    s.reload
    assert s.redeemed_at.present?
    assert s.automation_rule.present?
  end

  test "redeem!: refuses to mint a second rule when another setup for the same agent already redeemed" do
    # Two separate HarmonicBridgeSetup rows for the same agent — both passed
    # create-time validation because the first hadn't redeemed yet. The
    # second redeem! must refuse so we don't end up with two pending rules +
    # two long-lived tokens for one agent.
    first = build_setup
    first.save!
    second = build_setup
    second.save!

    first.redeem!
    assert_raises(HarmonicBridgeSetup::ConflictingSetup) { second.redeem! }
    assert_equal 1, @agent.api_tokens.count
    assert_equal 1, AutomationRule.where(ai_agent_id: @agent.id).count
    second.reload
    assert_nil second.redeemed_at, "loser stays unredeemed"
    assert_nil second.api_token
    assert_nil second.automation_rule
  end

  # ---------- stage_webhook! ----------

  test "stage_webhook!: fills the URL on the rule but leaves it disabled" do
    s = build_setup
    s.save!
    credentials = s.redeem!
    original_rule_id = s.automation_rule.id
    original_secret = s.automation_rule.webhook_secret

    webhook_url = "https://agent.example.test/webhook/#{@agent.tenant_users.find_by(tenant_id: @tenant.id).handle}"
    s.stage_webhook!(webhook_url: webhook_url, events: ["notifications.delivered"])

    s.reload
    rule = s.automation_rule
    assert_not_nil rule
    assert_equal original_rule_id, rule.id, "same rule as the one created at redeem time"
    assert_equal original_secret, rule.webhook_secret, "secret is unchanged"
    assert_equal credentials[:signing_secret], rule.webhook_secret
    assert_equal "event", rule.trigger_type
    assert_equal ["notifications.delivered"], rule.trigger_config["event_types"]
    assert_equal webhook_url, rule.actions["webhook_url"]
    assert_not rule.enabled?, "rule must stay disabled until verification succeeds"
    assert_nil s.webhook_registered_at, "webhook_registered_at waits for finalize_webhook!"
  end

  test "stage_webhook!: raises if not yet redeemed" do
    s = build_setup
    s.save!
    assert_raises(HarmonicBridgeSetup::NotYetRedeemed) do
      s.stage_webhook!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    end
  end

  test "stage_webhook!: raises if already finalized" do
    s = build_setup
    s.save!
    s.redeem!
    s.stage_webhook!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    s.finalize_webhook!
    assert_raises(HarmonicBridgeSetup::WebhookAlreadyRegistered) do
      s.stage_webhook!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    end
  end

  test "stage_webhook!: raises if expired" do
    s = build_setup
    s.save!
    s.redeem!
    s.update_columns(expires_at: 1.minute.ago)
    assert_raises(HarmonicBridgeSetup::Expired) do
      s.stage_webhook!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    end
  end

  test "stage_webhook!: re-runnable when crash happened before finalize_webhook!" do
    # If complete! enabled the rule before verification, a crash between then
    # and revert_completion! left an unverified webhook live. With the
    # disabled-until-finalize split, a retry of POST is safe: stage_webhook!
    # re-runs and overwrites the URL while the rule stays disabled.
    s = build_setup
    s.save!
    s.redeem!
    s.stage_webhook!(webhook_url: "https://first.example/y", events: ["notifications.delivered"])
    s.stage_webhook!(webhook_url: "https://second.example/y", events: ["reminders.delivered"])
    s.reload
    rule = s.automation_rule
    assert_equal "https://second.example/y", rule.actions["webhook_url"]
    assert_equal ["reminders.delivered"], rule.trigger_config["event_types"]
    assert_not rule.enabled?
    assert_nil s.webhook_registered_at
  end

  # ---------- finalize_webhook! ----------

  test "finalize_webhook!: enables the rule and stamps webhook_registered_at" do
    s = build_setup
    s.save!
    s.redeem!
    s.stage_webhook!(webhook_url: "https://x/y", events: ["notifications.delivered"])

    s.finalize_webhook!

    s.reload
    assert s.automation_rule.enabled?
    assert s.webhook_registered_at.present?
  end

  test "finalize_webhook!: raises if no webhook has been staged" do
    s = build_setup
    s.save!
    s.redeem!
    assert_raises(HarmonicBridgeSetup::WebhookNotStaged) { s.finalize_webhook! }
  end

  test "finalize_webhook!: raises if already finalized" do
    s = build_setup
    s.save!
    s.redeem!
    s.stage_webhook!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    s.finalize_webhook!
    assert_raises(HarmonicBridgeSetup::WebhookAlreadyRegistered) { s.finalize_webhook! }
  end

  # ---------- revert_completion! ----------

  test "revert_completion!: destroys the token and the AutomationRule" do
    s = build_setup
    s.save!
    s.redeem!
    s.stage_webhook!(webhook_url: "https://x/y", events: ["notifications.delivered"])
    s.finalize_webhook!

    rule_id = s.automation_rule.id
    token_id = s.api_token.id

    s.revert_completion!

    assert_nil s.automation_rule
    assert_nil s.api_token
    assert_nil s.webhook_registered_at
    assert s.redeemed_at.present?, "redeemed_at stays set (the URL has been consumed)"
    assert_nil AutomationRule.find_by(id: rule_id)
    assert_nil ApiToken.find_by(id: token_id)

    # The setup is no longer POSTable — caller must get a fresh URL.
    assert_not s.webhook_registerable?
  end
end
