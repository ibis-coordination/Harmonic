# typed: false

require "test_helper"

class AgentSignupMailerTest < ActiveSupport::TestCase
  setup do
    @tenant, _collective, @human = create_tenant_collective_user
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    mark_activated!(@human)
    @signup = AgentSignup.start!(
      tenant: @tenant,
      principal_email: @human.email,
      name: "Click here http://evil.example to win",
      handle: "evil-handle"
    )
  end

  teardown do
    Tenant.clear_thread_scope
  end

  test "claim email goes to the named principal" do
    email = AgentSignupMailer.claim(@human, @signup.public_id, @tenant)

    assert_equal [@human.email], email.to
    assert_match(/agent/i, email.subject)
  end

  test "claim email links to the claim page on the signup's tenant" do
    body = AgentSignupMailer.claim(@human, @signup.public_id, @tenant).body.encoded

    assert_includes body, "https://#{@tenant.subdomain}.#{ENV.fetch("HOSTNAME", nil)}/agent-signups/#{@signup.public_id}/claim"
  end

  test "claim email carries no agent-supplied text" do
    email = AgentSignupMailer.claim(@human, @signup.public_id, @tenant)

    [email.subject, email.body.encoded].each do |text|
      assert_not_includes text, "evil.example"
      assert_not_includes text, "evil-handle"
    end
  end

  test "claim email carries neither the pairing code nor the poll secret" do
    body = AgentSignupMailer.claim(@human, @signup.public_id, @tenant).body.encoded

    assert_not_includes body, @signup.pairing_code
    assert_not_includes body, @signup.poll_secret
  end
end
