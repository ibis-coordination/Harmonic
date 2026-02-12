# typed: false

require "test_helper"

class DecisionParticipantTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @superagent = @global_superagent
    @user = @global_user
    Superagent.scope_thread_to_superagent(
      subdomain: @tenant.subdomain,
      handle: @superagent.handle
    )
  end

  test "requires user" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    participant = DecisionParticipant.new(
      tenant: @tenant,
      superagent: @superagent,
      decision: decision,
      user: nil
    )

    assert_not participant.valid?
    assert_includes participant.errors[:user], "must exist"
  end

  test "valid with user" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    participant = DecisionParticipant.new(
      tenant: @tenant,
      superagent: @superagent,
      decision: decision,
      user: @user
    )

    assert participant.valid?
  end

  test "authenticated? returns true" do
    decision = create_decision(tenant: @tenant, superagent: @superagent, created_by: @user)

    participant = DecisionParticipant.create!(
      tenant: @tenant,
      superagent: @superagent,
      decision: decision,
      user: @user
    )

    assert participant.authenticated?
  end
end
