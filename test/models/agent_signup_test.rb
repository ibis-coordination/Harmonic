require "test_helper"

class AgentSignupTest < ActiveSupport::TestCase
  def setup
    @tenant, _collective, @human = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    mark_activated!(@human)
  end

  def teardown
    Tenant.clear_thread_scope
  end

  def start(email: @human.email, name: "Stickman", handle: nil)
    AgentSignup.start!(tenant: @tenant, principal_email: email, name: name, handle: handle)
  end

  # ---------- start! ----------

  test "start!: creates a pending signup addressed to an eligible member" do
    signup = start

    assert signup.persisted?
    assert_equal "pending", signup.state
    assert_equal @human.id, signup.principal_user_id
    assert_equal "Stickman", signup.proposed_name
    assert signup.public_id.length >= 30, "public_id should be high-entropy"
    assert_in_delta 24.hours.from_now, signup.expires_at, 5.seconds
  end

  test "start!: exposes the poll secret and pairing code once, storing only digests" do
    signup = start

    assert signup.poll_secret.length >= 40
    assert_match(/\A\d{6}\z/, signup.pairing_code)
    assert_not_equal signup.poll_secret, signup.poll_secret_digest
    assert_not_includes signup.attributes.values.map(&:to_s), signup.poll_secret
    assert_not_includes signup.attributes.values.map(&:to_s), signup.pairing_code

    reloaded = AgentSignup.find(signup.id)
    assert_nil reloaded.poll_secret
    assert_nil reloaded.pairing_code
  end

  test "start!: does not store the principal email" do
    signup = start(email: "stranger@example.com")

    assert_not_includes AgentSignup.column_names, "principal_email"
    assert_not_includes signup.attributes.values.map(&:to_s), "stranger@example.com"
  end

  test "start!: matches the member's email case-insensitively and ignores whitespace" do
    signup = start(email: "  #{@human.email.upcase} ")

    assert_equal @human.id, signup.principal_user_id
  end

  test "start!: leaves the principal nil for an unknown email" do
    signup = start(email: "nobody-#{SecureRandom.hex(4)}@example.com")

    assert signup.persisted?
    assert_nil signup.principal_user_id
    assert_equal "pending", signup.state
  end

  test "start!: leaves the principal nil for a user who is not a member of this tenant" do
    outsider = create_user
    mark_activated!(outsider)

    assert_nil start(email: outsider.email).principal_user_id
  end

  test "start!: leaves the principal nil for a member with an unverified email" do
    member = create_user
    @tenant.add_user!(member)

    assert_nil start(email: member.email).principal_user_id
  end

  test "start!: leaves the principal nil for a suspended member" do
    @human.update!(suspended_at: Time.current)

    assert_nil start.principal_user_id
  end

  test "start!: leaves the principal nil for a member pending deletion" do
    @human.update!(deletion_requested_at: Time.current)

    assert_nil start.principal_user_id
  end

  test "start!: leaves the principal nil for a non-human user" do
    agent = create_ai_agent(parent: @human, name: "Existing Agent")
    @tenant.add_user!(agent)

    assert_nil start(email: agent.email).principal_user_id
  end

  test "start!: requires a name and caps name and handle length" do
    assert_raises(ActiveRecord::RecordInvalid) { start(name: "") }
    assert_raises(ActiveRecord::RecordInvalid) { start(name: "x" * (AgentSignup::MAX_NAME_LENGTH + 1)) }
    assert_raises(ActiveRecord::RecordInvalid) { start(handle: "h" * (AgentSignup::MAX_HANDLE_LENGTH + 1)) }
  end

  test "start!: a fourth pending signup for the same principal expires the oldest" do
    oldest = start
    travel 1.minute
    second = start
    travel 1.minute
    third = start
    travel 1.minute
    fourth = start

    assert oldest.reload.expired?
    assert_not second.reload.expired?
    assert_not third.reload.expired?
    assert_not fourth.reload.expired?
  end

  test "start!: unmatched signups do not count against any principal's cap" do
    mine = start
    4.times { start(email: "nobody-#{SecureRandom.hex(4)}@example.com") }

    assert_not mine.reload.expired?
  end

  # ---------- poll secret ----------

  test "poll_secret_matches?: true only for the issued secret" do
    signup = start
    reloaded = AgentSignup.find(signup.id)

    assert reloaded.poll_secret_matches?(signup.poll_secret)
    assert_not reloaded.poll_secret_matches?("wrong")
    assert_not reloaded.poll_secret_matches?("")
    assert_not reloaded.poll_secret_matches?(nil)
  end

  # ---------- pairing code ----------

  test "verify_pairing_code!: accepts the issued code without counting a failure" do
    signup = start
    reloaded = AgentSignup.find(signup.id)

    assert reloaded.verify_pairing_code!(signup.pairing_code)
    assert_equal 0, reloaded.reload.failed_pairing_attempts
  end

  test "verify_pairing_code!: tolerates spaces and dashes in the typed code" do
    signup = start
    code = signup.pairing_code

    assert AgentSignup.find(signup.id).verify_pairing_code!(" #{code[0..2]}-#{code[3..]} ")
  end

  test "verify_pairing_code!: a wrong code counts a failure" do
    signup = start

    assert_not signup.verify_pairing_code!(wrong_code_for(signup))
    assert_equal 1, signup.reload.failed_pairing_attempts
    assert_not signup.expired?
  end

  test "verify_pairing_code!: the fifth failure expires the signup, and the right code no longer works" do
    signup = start
    code = signup.pairing_code
    wrong = wrong_code_for(signup)

    AgentSignup::MAX_PAIRING_ATTEMPTS.times { signup.verify_pairing_code!(wrong) }

    assert signup.reload.expired?
    assert_not signup.verify_pairing_code!(code)
  end

  # ---------- claim ----------

  test "claimable_by?: only the named principal, only while pending and unexpired" do
    signup = start
    other = create_user
    @tenant.add_user!(other)

    assert signup.claimable_by?(@human)
    assert_not signup.claimable_by?(other)
    assert_not signup.claimable_by?(nil)

    travel 25.hours do
      assert_not signup.claimable_by?(@human)
    end
  end

  test "claimable_by?: never true for an unmatched signup" do
    signup = start(email: "nobody-#{SecureRandom.hex(4)}@example.com")

    assert_not signup.claimable_by?(@human)
  end

  test "claim!: records the agent and restarts the expiry clock for pickup" do
    signup = start
    agent = create_ai_agent(parent: @human, name: "Stickman", agent_configuration: { "mode" => "external" })

    travel 23.hours do
      signup.claim!(ai_agent: agent)

      assert_equal "claimed", signup.state
      assert_equal agent.id, signup.ai_agent_user_id
      assert_in_delta Time.current, signup.claimed_at, 5.seconds
      assert_in_delta 24.hours.from_now, signup.expires_at, 5.seconds
      assert_not signup.claimable_by?(@human)
    end
  end

  test "claim!: refuses a signup that is not pending" do
    signup = start
    agent = create_ai_agent(parent: @human, name: "Stickman", agent_configuration: { "mode" => "external" })
    signup.decline!

    assert_raises(AgentSignup::NotClaimable) { signup.claim!(ai_agent: agent) }
  end

  test "claim!: refuses an agent whose principal is not the named principal" do
    signup = start
    other = create_user
    @tenant.add_user!(other)
    agent = create_ai_agent(parent: other, name: "Someone Else's", agent_configuration: { "mode" => "external" })

    assert_raises(AgentSignup::NotClaimable) { signup.claim!(ai_agent: agent) }
  end

  test "decline!: marks a pending signup declined" do
    signup = start
    signup.decline!

    assert_equal "declined", signup.state
    assert_not signup.claimable_by?(@human)
  end

  # ---------- agent-facing status ----------

  test "agent_status: reflects the lifecycle" do
    signup = start
    assert_equal "pending", signup.agent_status

    travel 25.hours do
      assert_equal "expired", signup.agent_status
    end

    declined = start
    declined.decline!
    assert_equal "declined", declined.agent_status
  end

  test "agent_status: ready once claimed, claimed_awaiting_billing while the agent is parked" do
    signup = start
    agent = create_ai_agent(parent: @human, name: "Stickman", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    signup.claim!(ai_agent: agent)
    assert_equal "ready", signup.agent_status

    agent.update!(pending_billing_setup: true)
    assert_equal "claimed_awaiting_billing", signup.reload.agent_status
  end

  test "agent_status: not ready while the agent is archived or suspended" do
    signup = start
    agent = create_ai_agent(parent: @human, name: "Stickman", agent_configuration: { "mode" => "external" })
    membership = @tenant.add_user!(agent)
    signup.claim!(ai_agent: agent)

    membership.archive!
    assert_equal "claimed_awaiting_billing", signup.reload.agent_status

    membership.unarchive!
    agent.update!(suspended_at: Time.current)
    assert_equal "claimed_awaiting_billing", signup.reload.agent_status
  end

  test "agent_status: an unmatched signup is indistinguishable from a matched one" do
    assert_equal "pending", start(email: "nobody-#{SecureRandom.hex(4)}@example.com").agent_status
  end

  # ---------- pickup ----------

  test "pick_up!: mints an MCP token for the claimed agent and marks the signup redeemed" do
    signup, agent = claimed_signup

    plaintext = signup.pick_up!

    token = ApiToken.authenticate(plaintext, tenant_id: @tenant.id)
    assert_equal agent.id, token.user_id
    assert token.mcp_type?
    assert_equal "redeemed", signup.state
    assert_equal token.id, signup.api_token_id
    assert_in_delta Time.current, signup.redeemed_at, 5.seconds
    assert_equal "redeemed", signup.agent_status
  end

  test "pick_up!: returns nil and mints nothing the second time" do
    signup, agent = claimed_signup
    signup.pick_up!

    assert_no_difference -> { ApiToken.where(user_id: agent.id).count } do
      assert_nil signup.pick_up!
    end
  end

  test "pick_up!: returns nil and mints nothing before the claim" do
    signup = start

    assert_no_difference -> { ApiToken.count } do
      assert_nil signup.pick_up!
    end
    assert_equal "pending", signup.state
  end

  test "pick_up!: returns nil while the agent is waiting on billing" do
    signup, agent = claimed_signup
    agent.update!(pending_billing_setup: true)

    assert_no_difference -> { ApiToken.where(user_id: agent.id).count } do
      assert_nil signup.pick_up!
    end
    assert_equal "claimed", signup.reload.state
  end

  test "pick_up!: returns nil once the pickup window has lapsed" do
    signup, agent = claimed_signup

    travel 25.hours do
      assert_no_difference -> { ApiToken.where(user_id: agent.id).count } do
        assert_nil signup.pick_up!
      end
      assert_equal "expired", signup.agent_status
    end
  end

  # ---------- feature flag ----------

  test "tenant: agent signup is on only when external agents are also on" do
    @tenant.set_feature_flag!("agent_signup", true)
    @tenant.set_feature_flag!("external_ai_agents", false)
    assert_not @tenant.agent_signup_enabled?

    @tenant.set_feature_flag!("external_ai_agents", true)
    assert @tenant.agent_signup_enabled?

    @tenant.set_feature_flag!("agent_signup", false)
    assert_not @tenant.agent_signup_enabled?
  end

  # ---------- integrity ----------

  test "the database rejects an unknown state" do
    signup = start

    assert_raises(ActiveRecord::StatementInvalid) do
      signup.update_column(:state, "bogus")
    end
  end

  test "public_id is unique per tenant" do
    signup = start
    dup = AgentSignup.new(tenant: @tenant, proposed_name: "Dup", public_id: signup.public_id)

    assert_not dup.valid?
    assert dup.errors.key?(:public_id)
  end

  private

  def claimed_signup
    signup = start
    agent = create_ai_agent(parent: @human, name: "Stickman", agent_configuration: { "mode" => "external" })
    @tenant.add_user!(agent)
    signup.claim!(ai_agent: agent)
    [signup, agent]
  end

  def wrong_code_for(signup)
    signup.pairing_code == "000000" ? "111111" : "000000"
  end
end
