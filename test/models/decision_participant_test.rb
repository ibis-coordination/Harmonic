# typed: false

require "test_helper"

class DecisionParticipantTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    Collective.scope_thread_to_collective(
      subdomain: @tenant.subdomain,
      handle: @collective.handle
    )
  end

  test "requires user" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    participant = DecisionParticipant.new(
      tenant: @tenant,
      collective: @collective,
      decision: decision,
      user: nil
    )

    assert_not participant.valid?
    assert_includes participant.errors[:user], "must exist"
  end

  test "valid with user" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    participant = DecisionParticipant.new(
      tenant: @tenant,
      collective: @collective,
      decision: decision,
      user: @user
    )

    assert participant.valid?
  end

  test "authenticated? returns true" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    participant = DecisionParticipant.create!(
      tenant: @tenant,
      collective: @collective,
      decision: decision,
      user: @user
    )

    assert participant.authenticated?
  end
end
